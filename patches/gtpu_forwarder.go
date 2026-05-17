// Copyright 2026 - Userspace GTP-U forwarder for kernels without XDP support

package upf

import (
	"context"
	"encoding/binary"
	"net"
	"net/netip"
	"unsafe"

	"github.com/ellanetworks/core/internal/logger"
	"github.com/ellanetworks/core/internal/upf/ebpf"
	"github.com/songgao/water"
	"github.com/vishvananda/netlink"
	"go.uber.org/zap"
)

const (
	gtpuPort       = 2152
	gtpuHeaderSize = 8
	// GTP-U flags: version=1, PT=1, E=0, S=0, PN=0
	gtpuFlags = 0x30
	gtpuMsgT  = 0xFF // G-PDU
)

// runUserspaceForwarder implements a simple GTP-U ↔ TUN forwarder.
// Uplink: GTP-U on N3 (UDP:2152) → decap → write to TUN (ogstun)
// Downlink: read from TUN → lookup UE IP → encap GTP-U → send to gNB
func (u *UPF) runUserspaceForwarder(ctx context.Context, n3Addr string, n3IfIndex int) {
	// Create TUN device for UE traffic (use "ellatun" to avoid conflict with Open5GS ogstun)
	tunName := "ellatun"
	tun, err := createOrOpenTun(tunName, "10.45.0.1/16")
	if err != nil {
		logger.UpfLog.Error("Failed to create/open TUN device", zap.Error(err))
		return
	}
	defer tun.Close()

	// Listen for GTP-U on N3
	listenAddr := net.JoinHostPort(n3Addr, "2152")
	udpAddr, err := net.ResolveUDPAddr("udp4", listenAddr)
	if err != nil {
		logger.UpfLog.Error("Failed to resolve GTP-U listen address", zap.Error(err))
		return
	}

	conn, err := net.ListenUDP("udp4", udpAddr)
	if err != nil {
		logger.UpfLog.Error("Failed to listen for GTP-U", zap.String("addr", listenAddr), zap.Error(err))
		return
	}
	defer conn.Close()

	logger.UpfLog.Info("Userspace GTP-U forwarder listening",
		zap.String("addr", listenAddr),
		zap.String("tun", tunName),
	)

	// Uplink: GTP-U → TUN
	go u.forwardUplink(ctx, conn, tun)

	// Downlink: TUN → GTP-U (blocks until context cancelled)
	u.forwardDownlink(ctx, tun, conn)
}

func (u *UPF) forwardUplink(ctx context.Context, conn *net.UDPConn, tun *water.Interface) {
	buf := make([]byte, 65536)

	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		n, _, err := conn.ReadFromUDP(buf)
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			logger.UpfLog.Debug("GTP-U read error", zap.Error(err))
			continue
		}

		if n < gtpuHeaderSize {
			continue
		}

		// Parse GTP-U header
		flags := buf[0]
		if flags&0xE0 != 0x20 { // version must be 1
			continue
		}

		teid := binary.BigEndian.Uint32(buf[4:8])

		// Calculate inner packet offset (handle extension headers)
		offset := gtpuHeaderSize
		if flags&0x07 != 0 { // E, S, or PN flag set
			if n < offset+4 {
				continue
			}
			offset += 4 // sequence number + N-PDU number + next ext header type
			if flags&0x04 != 0 { // Extension header flag
				for offset < n {
					if offset >= n {
						break
					}
					extLen := int(buf[offset]) * 4
					if extLen == 0 {
						break
					}
					offset += extLen
					if offset > n {
						break
					}
					if buf[offset-1] == 0 {
						break
					}
				}
			}
		}

		if offset >= n {
			continue
		}

		innerPacket := buf[offset:n]

		// Look up PDR by TEID in BPF map
		pdr, ok := u.lookupUplinkPDR(teid)
		if !ok {
			logger.UpfLog.Debug("No PDR for TEID", logger.TEID(teid))
			continue
		}

		// Account traffic via URR
		if pdr.UrrId != 0 {
			incrementURR(u.se.BpfObjects, pdr.UrrId, uint64(len(innerPacket)))
		}

		// Write inner packet to TUN
		_, err = tun.Write(innerPacket)
		if err != nil {
			logger.UpfLog.Debug("TUN write error", zap.Error(err))
		}
	}
}

func (u *UPF) forwardDownlink(ctx context.Context, tun *water.Interface, conn *net.UDPConn) {
	buf := make([]byte, 65536)
	gtpBuf := make([]byte, 65536+gtpuHeaderSize)

	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		n, err := tun.Read(buf)
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			logger.UpfLog.Debug("TUN read error", zap.Error(err))
			continue
		}

		if n < 20 { // minimum IPv4 header
			continue
		}

		// Extract destination IP from inner packet
		version := buf[0] >> 4
		var dstAddr netip.Addr
		if version == 4 {
			dstAddr = netip.AddrFrom4([4]byte(buf[16:20]))
		} else if version == 6 && n >= 40 {
			dstAddr = netip.AddrFrom16([16]byte(buf[24:40]))
		} else {
			continue
		}

		// Look up PDR by UE IP in BPF map
		pdr, ok := u.lookupDownlinkPDR(dstAddr)
		if !ok {
			continue
		}

		// Account traffic via URR
		if pdr.UrrId != 0 {
			incrementURR(u.se.BpfObjects, pdr.UrrId, uint64(n))
		}

		// Check FAR action: 2 = forward
		if pdr.Far.Action != 2 {
			continue
		}

		// Build GTP-U header
		gtpBuf[0] = gtpuFlags
		gtpBuf[1] = gtpuMsgT
		binary.BigEndian.PutUint16(gtpBuf[2:4], uint16(n))
		binary.BigEndian.PutUint32(gtpBuf[4:8], pdr.Far.Teid)

		// Copy inner packet after GTP-U header
		copy(gtpBuf[gtpuHeaderSize:], buf[:n])

		// Get remote gNB address from FAR
		remoteIP := ebpf.In6AddrToIP(pdr.Far.Remoteip.In6U.U6Addr8)
		if !remoteIP.IsValid() {
			continue
		}

		dstUDP := &net.UDPAddr{
			IP:   remoteIP.AsSlice(),
			Port: gtpuPort,
		}

		_, err = conn.WriteToUDP(gtpBuf[:gtpuHeaderSize+n], dstUDP)
		if err != nil {
			logger.UpfLog.Debug("GTP-U send error", zap.Error(err))
		}
	}
}

// lookupUplinkPDR looks up a PDR by TEID using the BPF map.
func (u *UPF) lookupUplinkPDR(teid uint32) (ebpf.N3N6EntrypointPdrInfo, bool) {
	var pdr ebpf.N3N6EntrypointPdrInfo
	if u.se.BpfObjects.PdrsUplink == nil {
		return pdr, false
	}
	err := u.se.BpfObjects.PdrsUplink.Lookup(teid, unsafe.Pointer(&pdr))
	if err != nil {
		return pdr, false
	}
	return pdr, true
}

// lookupDownlinkPDR looks up a PDR by UE IP using the BPF map.
func (u *UPF) lookupDownlinkPDR(addr netip.Addr) (ebpf.N3N6EntrypointPdrInfo, bool) {
	var pdr ebpf.N3N6EntrypointPdrInfo
	if addr.Is4() {
		if u.se.BpfObjects.PdrsDownlinkIp4 == nil {
			return pdr, false
		}
		key := addr.As4()
		err := u.se.BpfObjects.PdrsDownlinkIp4.Lookup(key, unsafe.Pointer(&pdr))
		if err != nil {
			return pdr, false
		}
		return pdr, true
	}
	if u.se.BpfObjects.PdrsDownlinkIp6 == nil {
		return pdr, false
	}
	key := addr.As16()
	err := u.se.BpfObjects.PdrsDownlinkIp6.Lookup(key, unsafe.Pointer(&pdr))
	if err != nil {
		return pdr, false
	}
	return pdr, true
}

// incrementURR safely increments URR counters in the BPF per-CPU array map.
func incrementURR(bpfObjs *ebpf.BpfObjects, urrID uint32, bytes uint64) {
	if bpfObjs.UrrMap == nil {
		return
	}
	var perCPU []uint64
	if err := bpfObjs.UrrMap.Lookup(&urrID, &perCPU); err != nil {
		return
	}
	if len(perCPU) > 0 {
		perCPU[0] += bytes
	}
	_ = bpfObjs.UrrMap.Update(&urrID, perCPU, 0)
}

// --- TUN device management ---

func createOrOpenTun(name string, cidr string) (*water.Interface, error) {
	config := water.Config{
		DeviceType: water.TUN,
	}
	config.Name = name

	tun, err := water.New(config)
	if err != nil {
		return nil, err
	}

	// Configure the interface
	link, err := netlink.LinkByName(name)
	if err != nil {
		tun.Close()
		return nil, err
	}

	addr, err := netlink.ParseAddr(cidr)
	if err != nil {
		tun.Close()
		return nil, err
	}

	if err := netlink.AddrAdd(link, addr); err != nil {
		// Address may already exist
		logger.UpfLog.Debug("TUN addr add (may already exist)", zap.Error(err))
	}

	if err := netlink.LinkSetUp(link); err != nil {
		tun.Close()
		return nil, err
	}

	logger.UpfLog.Info("TUN device ready", zap.String("name", name), zap.String("cidr", cidr))

	return tun, nil
}
