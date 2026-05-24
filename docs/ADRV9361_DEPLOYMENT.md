# Deploying Ella Core on ADRV9361-Z7035

This guide covers building a minimal Debian armhf SD card with Ella Core for the ADI ADRV9361-Z7035 board (Xilinx Zynq-7035 + AD9361 RF transceiver).

## Hardware

- **SOM**: ADRV9361-Z7035 (Xilinx Zynq-7035: dual-core ARM Cortex-A9 @ 666 MHz, ~1 GB DDR3)
- **Carrier**: ADRV1CRR-BOB
- **SD card**: 4+ GB (uses ~250 MB)
- **UART**: Micro-USB on carrier → `/dev/ttyUSB0` @ 115200 baud
- **Ethernet**: RJ45 → direct cable to host or switch

## Architectural Split

This deployment targets a **disaggregated 5G stack** where the heavy DSP runs elsewhere:

### Phase A — current target
```
Jetson AGX Orin                 ADRV9361-Z7035
┌─────────────────────┐         ┌──────────────────┐
│  L1 + L2 + L3 gNB   │◄───────►│   Ella Core 5G   │
│  (srsRAN or OAI)    │  NGAP   │   (this guide)   │
│                     │  GTP-U  │                  │
│  + ADRV9361 SDR     │         │                  │
└─────────────────────┘         └──────────────────┘
       UE phone
        via RF
```

### Phase B — eventual target
```
Jetson AGX Orin                 ADRV9361-Z7035
┌─────────────────────┐         ┌──────────────────┐
│  L1 only (PHY)      │◄───────►│  L2+L3 + 5GC     │
│  (FPGA + SDR)       │  FAPI   │                  │
└─────────────────────┘         └──────────────────┘
```

Phase A is the current focus — the board is just a 5G core appliance.

## Footprint on the Board

| | This SD card | ADI Kuiper |
|---|---|---|
| Boot partition | 13 MB | ~200 MB |
| Root partition | 218 MB | 7-12 GB |
| Total SD usage | ~230 MB | 7-12 GB |
| Boot time | ~10s (estimated) | ~45s |
| Running processes | systemd + ssh + ella-core (~5) | 30+ |

## Prerequisites on Build Host (Jetson)

```bash
sudo apt-get install -y \
  debootstrap qemu-user-static qemu-utils binfmt-support \
  gcc-arm-linux-gnueabihf parted dosfstools e2fsprogs \
  curl unzip openssl
```

Plus Go 1.26+:
```bash
wget https://go.dev/dl/go1.26.2.linux-arm64.tar.gz
sudo tar -C /usr/local -xzf go1.26.2.linux-arm64.tar.gz
```

## Build Steps

### 1. Cross-compile Ella Core for armv7

```bash
./sd-card/cross-compile.sh
```

This clones ellanetworks/core@v1.10.2, applies our patches, and builds:
- `~/ella-core/core-armv7` — 50 MB unstripped (35 MB stripped)

### 2. Build the SD card

```bash
# Identify your SD card
lsblk

# Set the device (CAREFUL — this is destructive)
sudo SD_DEVICE=/dev/sdX ./sd-card/build-sd-card.sh
```

Steps performed by the script:
1. Wipes the SD card
2. Creates MBR partition table + FAT32 boot + ext4 rootfs
3. Downloads ADI Kuiper image (3.5 GB, only for boot files)
4. Extracts BOOT.BIN + uImage + devicetree.dtb
5. Writes uEnv.txt for U-Boot
6. debootstrap minimal Debian Bookworm armhf
7. Configures network (static 169.254.237.42), SSH, hostname
8. Installs Ella Core binary + systemd service
9. Strips bloat (docs, man pages, apt cache)
10. Final size: ~230 MB

Total time: ~20 min download + ~5 min build (first run), <5 min subsequent.

## First Boot

1. Insert SD card into the ADRV1CRR-BOB SD slot
2. Connect UART via micro-USB to host
3. Open serial console: `sudo picocom -b 115200 /dev/ttyUSB0`
4. Power on the board
5. Watch for:
   - FSBL boot
   - U-Boot loading kernel + DTB
   - Linux boot to login prompt

## Connecting

### Via UART
```
adrv5gc login: root
Password: analog
```

### Via SSH (after boot)
Host must have `169.254.237.x` address on Ethernet interface:
```bash
# On Jetson/host
sudo ip addr add 169.254.237.1/16 dev eno1

# SSH to board
ssh root@169.254.237.42  # password: analog
```

### Via REST API
```bash
curl -k https://169.254.237.42:5002/api/v1/status
```

## Ella Core Configuration

The pre-installed config (`/opt/ella-core/core.yaml`) listens on:
- **N2 (NGAP/SCTP)**: 169.254.237.42:38412
- **N3 (GTP-U/UDP)**: 169.254.237.42:2152 (via userspace forwarder)
- **API (HTTPS)**: 0.0.0.0:5002

UE traffic exits via `eth0` with NAT (UEs get IPs from 10.45.0.0/22 by default).

## Connecting a gNB

From the Jetson (running srsRAN/OAI gNB), point at the board's AMF:

**srsRAN gnb yaml:**
```yaml
cu_cp:
  amf:
    addr: 169.254.237.42
    port: 38412
    bind_addr: 169.254.237.1
    supported_tracking_areas:
      - tac: 1
        plmn_list:
          - plmn: "00101"
            tai_slice_support_list:
              - sst: 1
```

**OAI gnb conf:**
```
amf_ip_address = ({ ipv4 = "169.254.237.42"; });
NETWORK_INTERFACES :
{
   GNB_IPV4_ADDRESS_FOR_NG_AMF = "169.254.237.1";
   GNB_IPV4_ADDRESS_FOR_NGU = "169.254.237.1";
   GNB_PORT_FOR_S1U = 2152;
};
```

## Provisioning a Subscriber

```bash
API="https://169.254.237.42:5002/api/v1"
TOKEN=$(curl -sk -X POST $API/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@dtc.io","password":"EllaTest2024!"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['token'])")

# First-time init
curl -sk -X POST $API/init -H "Content-Type: application/json" \
  -d '{"email":"admin@dtc.io","password":"EllaTest2024!"}'

# Set PLMN, TAC, OPc (one time)
curl -sk -X PUT $API/operator/id -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -d '{"mcc":"001","mnc":"01"}'

curl -sk -X PUT $API/operator/tracking -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -d '{"supportedTacs":["000001"]}'

curl -sk -X PUT $API/operator/code -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"operatorCode":"1185B494BDAC5B7909DEE705B017F165"}'

# Add subscriber
curl -sk -X POST $API/subscribers -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"imsi":"001010123456789","key":"96d2e48ab066384d0c61828f2b2fe5e3","opc":"1185b494bdac5b7909dee705b017f165","sequenceNumber":"000000000022","profile_name":"default"}'
```

## Notes & Caveats

### Kernel Modules
The ADI Zynq kernel (6.1.70) ships as a monolithic uImage — TUN/TAP, ext4, and networking are all built in. If a feature needs an out-of-tree module, you'd need to rebuild the kernel against ADI's `analogdevicesinc/linux` source.

### BPF/eBPF Support
The Cortex-A9 kernel may have limited eBPF capabilities. Our userspace UPF fallback automatically engages when the XDP program can't load — same code path proven on Jetson kernel 5.15.

### Performance Expectations
- Cortex-A9 dual-core @ 666 MHz vs Jetson AGX Orin (12× A78AE @ 2.2 GHz) — ~30× weaker
- Control plane (AMF/SMF/RRC signaling): comfortable
- Userspace UPF data plane: estimated 20-50 Mbps (limited by single-core packet forwarding through TUN)
- Suitable for low-rate LEO links (typical 5-50 Mbps user-plane rates)

### RAM
~1 GB total. Ella Core uses ~40 MB. Plenty of headroom for:
- Kernel + initrd: ~50 MB
- systemd + sshd + ella-core: ~80 MB
- Free: ~870 MB

## Recovery / Re-flash

If the board hangs or kernel panics, just re-run the build script with the SD card removed. Boot a fresh card. Old SD card can be re-flashed without touching the board.
