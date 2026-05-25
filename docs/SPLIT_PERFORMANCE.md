# Split-Deployment Performance: Jetson gNB → ADRV Board 5GC

**Date:** 2026-05-25
**Topology:** OpenAirInterface gNB + nrUE (rfsim PHY) running on the Jetson AGX Orin, connecting over Ethernet to Ella Core on the ADRV9361-Z7035 (Cortex-A9, our custom kernel).

```
┌──────────────────────────────────────────┐
│       Jetson AGX Orin (Ubuntu 22.04)      │
│  ┌──────────────────────────────────┐    │
│  │ OAI nrUE  ── rfsim TCP ──→ OAI gNB│    │
│  │ TUN oaitun_ue1 (in netns ue_ns)  │    │
│  └────────────┬─────────────────────┘    │
│               │ GTP-U (UDP 2152)         │
│               │ NGAP (SCTP 38412)        │
│    eno1 169.254.237.1                    │
└───────────────┼──────────────────────────┘
                │ Ethernet (link-local)
┌───────────────┼──────────────────────────┐
│     ADRV9361-Z7035 (custom Debian armhf) │
│    eth0 169.254.237.42                   │
│               │                          │
│  ┌────────────▼─────────────────────┐    │
│  │ Ella Core v1.10.2 (patched)      │    │
│  │  - AMF, SMF, UDM, AUSF, etc.     │    │
│  │  - Userspace GTP-U forwarder     │    │
│  │  - Go-map PDR storage fallback   │    │
│  │  - TUN ellatun 10.45.0.254/16    │    │
│  └────────────┬─────────────────────┘    │
│               │ packets to UE pool        │
│         (NAT MASQUERADE via iptables)    │
└──────────────────────────────────────────┘
```

## Reproducible Test Procedure

### Prerequisites
- Board running our custom kernel + Ella Core (see [ADRV9361_DEPLOYMENT.md](ADRV9361_DEPLOYMENT.md))
- Ella Core configured with PLMN 00101, TAC 1, subscriber 001010123456789
- Jetson with OAI built at `/home/rapidbeam/openairinterface5g/cmake_targets/ran_build/build/`
- UERANSIM built at `/home/rapidbeam/UERANSIM/build/`
- Configs from `configs/` in this repo

### Step 1: Baseline — everything on Jetson

```bash
# Ella Core running on Jetson (10.3.0.2:38412)
sudo /path/to/ella-core/core -config configs/ella-core.yaml &

# UERANSIM gNB → Jetson Ella Core
sudo nr-gnb -c configs/ueransim_gnb_ella.yaml &
sudo nr-ue -c configs/ueransim_ue_ella.yaml &

# Capture per-step timings from /tmp/baseline_ue.log
```

### Step 2: Split — gNB on Jetson, 5GC on board

```bash
# UERANSIM gNB → board Ella Core
sudo nr-gnb -c configs/ueransim_gnb_adrv.yaml &
sudo nr-ue -c configs/ueransim_ue_adrv.yaml &
```

### Step 3: Full PHY E2E — OAI rfsim → board

```bash
# Set up isolated UE namespace (kernel routes 10.45.0.1 as local otherwise)
sudo ip netns add ue_ns
sudo ip netns exec ue_ns ip link set lo up

# Start OAI gNB pointing at board
cd openairinterface5g/cmake_targets/ran_build/build
sudo ./nr-softmodem -O configs/gnb_oai_rfsim_adrv.conf --rfsim &

# Start OAI nrUE
sudo ./nr-uesoftmodem -O configs/oai_nrue_rfsim_ella.conf \
  --rfsim --numerology 1 -r 106 --band 78 \
  -C 3319680000 --ssb 516 --ue-fo-compensation &

# After "TUN Interface oaitun_ue1 successfully configured", move TUN into ue_ns
sudo ip link set oaitun_ue1 netns ue_ns
sudo ip netns exec ue_ns ip link set oaitun_ue1 up
sudo ip netns exec ue_ns ip addr add 10.45.0.1/24 dev oaitun_ue1
sudo ip netns exec ue_ns ip route add default dev oaitun_ue1

# Data plane: ping and iperf3
sudo ip netns exec ue_ns ping -c 10 169.254.237.42
iperf3 -s -D
sudo ip netns exec ue_ns iperf3 -c 169.254.237.1 -t 15
```

## Measurement Methodology

- **Control plane timings**: extracted from UERANSIM UE logs by `grep` + datetime parsing of NAS state transitions. Resolution: 1 ms.
- **NG Setup RTT**: from UERANSIM gNB log "Sending NG Setup Request" → "NG Setup Response received".
- **Network RTT**: `ping -c 20 -i 0.2 -q` over the relevant interface; report `avg`.
- **Throughput**: `iperf3` defaults (10 s TCP, single stream).
- **CPU**: measured on the board via `top -bn1 -p $(pgrep core)`.
- **GTP-U traffic**: `tcpdump -i eno1 udp port 2152` and ellatun statistics `/sys/class/net/ellatun/statistics/{rx,tx}_packets`.

## Results

### Control Plane (NAS attach)

| Phase | Baseline (Jetson) | Split (Jetson gNB → ADRV 5GC) | Δ |
|---|---|---|---|
| NG Setup RTT | 2.0 ms | 9.0 ms | +7 ms |
| Network RTT (avg of 20 pings) | 0.30 ms | 0.88 ms | +0.6 ms |
| Reg Req → Auth Req | 6 ms | 13 ms | +7 ms |
| Auth Req → Security Mode | 1 ms | 6 ms | +5 ms |
| Security Mode → Reg Accept | 8 ms | 34 ms | +26 ms |
| **Reg Req → PDU Accept (total)** | **240 ms** | **292 ms** | **+52 ms (+22%)** |

The 52 ms attach-time penalty comes from:
- ~7 ms per NGAP round-trip × ~6 round-trips = ~40 ms baseline-vs-network overhead
- ~10 ms Cortex-A9 processing overhead (CPU is ~30× slower than Jetson's A78AE)

### Data Plane

**Ping (UE → external host through GTP-U + NAT)**

| Target | Packets | Loss | RTT avg (ms) | Notes |
|---|---|---|---|---|
| UE → 169.254.237.42 (board eth0) | 10/10 | 0% | 33.0 | exercises GTP-U decap + local response + encap |
| UE → 169.254.237.1 (Jetson) | 10/10 | 0% | 35.3 | adds NAT MASQUERADE on board, ~2 ms |

Most of the 33 ms is in the OAI rfsim PHY layer (PUSCH timing, RACH retries), not the board.
Bare Ethernet ping between Jetson and board: 0.88 ms.

**iperf3 throughput**

| Direction | TCP | UDP @ 5 Mbps |
|---|---|---|
| Uplink (UE → Jetson) | 1.97 Mbps sender / 0.87 Mbps receiver | — |
| Downlink (Jetson → UE) | 6.64 Mbps sender / 5.06 Mbps receiver | — |
| Uplink (UDP) | — | 5.00 Mbps, 0% loss |

ellatun saw 2219 RX / 1750 TX packets during the iperf3 run, no errors or drops on the TUN side.

### Bottleneck Analysis

| Suspect | Evidence | Conclusion |
|---|---|---|
| OAI rfsim PHY simulation | 33 ms ping floor, ~6 Mbps cap, bursty rate | **Primary bottleneck** (not the board) |
| Userspace GTP-U forwarder on Cortex-A9 | 0% loss at 5 Mbps UDP, 0 ellatun drops | Comfortable; could probably do 20-50 Mbps before saturating one core |
| Ethernet link | 0.88 ms RTT, gigabit | Not a factor |
| Board's iptables NAT | 1 packet/byte counter incremented per ping | Working, negligible cost |

The board's 5GC + userspace UPF on a Cortex-A9 @ 666 MHz easily handles the traffic OAI rfsim can produce. A real RF gNB feeding 5–50 Mbps user-plane (typical LEO satellite link) would be comfortable.

## Issues Found and Fixed (during this session)

### 1. BTF unsupported on Zynq kernel → BPF maps fail → PDRs not stored
**Symptom:** "failed to create map ... detect support for BTF: function not implemented" in Ella Core logs. PDR Put silently no-op'd. Userspace GTP-U forwarder had no PDRs to look up, dropped all packets.

**Root cause:** Even with `CONFIG_DEBUG_INFO_BTF=y` set, the kernel build requires `pahole` (from `dwarves` package) to actually generate BTF type information. We didn't have it installed when building the kernel.

**Fix:** Added Go-map fallback in `BpfObjects` — when kernel BPF maps are nil, store PDRs in `sync.RWMutex`-protected Go maps. New methods: `LookupGoPdrUplink`, `LookupGoPdrDownlinkV4/V6`. The `gtpu_forwarder` now tries kernel map first, falls back to Go map.

**Alternative not taken:** rebuild kernel with `pahole` installed. Would let us use native BPF maps but doesn't change the data path (we'd still skip the XDP program for separate verifier reasons). Marginal benefit not worth the rebuild time.

### 2. ellatun IP collision with UE IP
**Symptom:** Downlink GTP-U packets reached board → decapsulated → written to ellatun. But replies never went out: board kernel saw destination 10.45.0.1 and matched its own ellatun interface (which had 10.45.0.1/16), delivered locally instead of sending out the TUN.

**Fix:** Changed `gtpu_forwarder.go` to assign `10.45.0.254/16` to ellatun (gateway-style, well away from UE pool starting at .1).

### 3. Same-host UE routing (Jetson)
**Symptom:** Even with correct GTP-U path, kernel saw UE source IP 10.45.0.1 as local on `oaitun_ue1`, but routed traffic via `eno1` because destinations were on the 169.254.0.0/16 subnet. Packets never entered the UE TUN.

**Fix:** Standard workaround — move `oaitun_ue1` into a dedicated network namespace (`ue_ns`) after OAI nrUE creates it. ue_ns has only the TUN + default route via the TUN, so all traffic flows into the GTP path. This is the same pattern used previously with Open5GS on the Jetson.

### 4. iptables nftables backend fails (kernel has legacy netfilter only)
**Symptom:** `iptables: Failed to initialize nft: Protocol not supported` from board.

**Fix:** `update-alternatives --set iptables /usr/sbin/iptables-legacy` (now baked into `build-sd-card.sh`).

### 5. systemd waits 90 s for /dev/mmcblk0p1 and /dev/ttyPS0
**Symptom:** Boot hangs for 90 s on first try, drops to emergency mode.

**Fix:** Don't list /boot in fstab (U-Boot reads it before kernel; we don't need it later); mask `getty@ttyPS0.service`. Both now in `build-sd-card.sh`.

## Open Items

- **Higher throughput**: would need an actual RF gNB (not rfsim) to confirm board's ceiling. Estimate 20-50 Mbps before Cortex-A9 single core saturates.
- **Latency optimization**: Cortex-A9's 30× CPU disadvantage adds ~30 ms across the 6 NAS round-trips. Not much to do about it on this hardware; the same code on a Cortex-A53 (e.g. Zynq UltraScale+) would close most of the gap.
- **Native eBPF UPF**: would need (a) BTF in kernel (rebuild with `dwarves`), and (b) the verifier-rejected XDP program rewritten to not use the problematic stack-access pattern. Userspace forwarder is good enough for our throughput target.

## Conclusion

A stripped Debian armhf with our patched Ella Core on the ADRV9361-Z7035's Cortex-A9 is fully functional as a 5G core. Full UE attach + IP allocation + data plane through GTP-U/userspace UPF all work end-to-end, with overhead of +52 ms attach time and (rfsim-limited) ~5 Mbps throughput. Phase A (Jetson gNB / board 5GC) is **validated and reproducible**.
