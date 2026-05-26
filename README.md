# Ella Core on Jetson AGX Orin — Lightweight 5G Core for Edge/Space

A patched deployment of [Ella Core](https://github.com/ellanetworks/core) v1.10.2 on NVIDIA Jetson AGX Orin (ARM64, kernel 5.15), with a userspace UPF data plane replacing the eBPF/XDP program that requires kernel 6.8+.

## Motivation

Open5GS runs 17 processes + MongoDB consuming ~873 MB RAM. For in-orbit or resource-constrained edge deployments, this is excessive. Ella Core delivers identical 5G SA functionality in a **single 50 MB binary using 37 MB RAM** — a 24x reduction.

## What's Here

```
ella-core-jetson/
├── README.md                          # This file
├── docs/
│   ├── ARCHITECTURE.md                # How the userspace UPF works
│   ├── TEST_RESULTS.md                # Full E2E test validation
│   └── ADRV9361_DEPLOYMENT.md         # Building a stripped Debian SD card
│                                      #   for ADRV9361-Z7035 (Zynq-7035)
├── configs/
│   ├── ella-core.yaml                 # Ella Core config (N2/N3/N6 interfaces)
│   ├── gnb_cpu_zmq_ella.yaml          # srsRAN gNB → Ella Core (ZMQ)
│   ├── gnb_oai_rfsim_ella.conf        # OAI gNB → Jetson Ella Core (rfsim)
│   ├── gnb_oai_rfsim_adrv.conf        # OAI gNB → ADRV board 5GC (rfsim)
│   ├── oai_nrue_rfsim_ella.conf       # OAI nrUE for rfsim testing
│   ├── ueransim_gnb_ella.yaml         # UERANSIM gNB → Jetson Ella Core
│   ├── ueransim_gnb_adrv.yaml         # UERANSIM gNB → ADRV board 5GC
│   ├── ueransim_ue_ella.yaml          # UERANSIM UE (Jetson 5GC)
│   └── ueransim_ue_adrv.yaml          # UERANSIM UE (ADRV board 5GC)
├── scripts/
│   ├── setup-ella-net.sh              # Create veth/dummy interfaces (Jetson)
│   ├── start-ella-core.sh             # Start the patched binary (Jetson)
│   └── test-split-perf.sh             # End-to-end performance test
│                                      #   (Jetson gNB → board 5GC)
├── sd-card/                           # ADRV9361-Z7035 deployment
│   ├── cross-compile.sh               # Build Ella Core for armv7
│   ├── build-sd-card.sh               # Build minimal Debian SD card
│   ├── build-kernel.sh                # Build custom Zynq kernel
│   │                                  #   (SCTP + netfilter + BTF + HZ_1000
│   │                                  #    + NO_HZ_FULL + RCU_NOCB)
│   ├── deploy-kernel.sh               # Replace uImage/dtb on SD card
│   └── build-oai-armhf.sh             # Cross-compile OAI nr-softmodem for armv7
│                                      #   (two-stage build, host generators + target)
└── patches/
    ├── userspace-upf-and-armv7.patch  # Git patch against ellanetworks/core v1.10.2
    │                                  #   (userspace UPF + nil-map guards + armv7 32-bit fixes)
    ├── gtpu_forwarder.go              # New file: userspace GTP-U forwarder
    └── oai-armhf.patch                # OAI patches for armv7 cross-compile
                                       #   (NEON shims + 32-bit int polyfill + stubs)
```

## Deployment Targets

| Target | Status | Doc |
|--------|--------|-----|
| Jetson AGX Orin (aarch64, kernel 5.15) | ✅ Validated | This README |
| ADRV9361-Z7035 (armv7, Cortex-A9) | ✅ Validated (full UE attach via custom kernel) | [ADRV9361_DEPLOYMENT.md](docs/ADRV9361_DEPLOYMENT.md), [results](docs/ADRV9361_RESULTS.md) |
| Split: Jetson gNB → ADRV 5GC (Ethernet) | ✅ Validated with OAI rfsim + data plane | [SPLIT_PERFORMANCE.md](docs/SPLIT_PERFORMANCE.md) |
| Phase B: Jetson L1 (PNF) → ADRV L2+L3+5GC (VNF) | 🚧 RT kernel + OAI armhf built; nFAPI config next | [PHASE_B_PROGRESS.md](docs/PHASE_B_PROGRESS.md) |

## Quick Start

### Prerequisites

- NVIDIA Jetson AGX Orin (or any ARM64 Linux with kernel 5.4+)
- Go 1.26+ (`/usr/local/go/bin/go`)
- At least one RAN: srsRAN Project, OpenAirInterface, or UERANSIM

### 1. Build Ella Core with Userspace UPF

```bash
git clone https://github.com/ellanetworks/core.git ~/ella-core
cd ~/ella-core
git checkout v1.10.2  # or latest
git apply ~/ella-core-jetson/patches/userspace-upf.patch
cp ~/ella-core-jetson/patches/gtpu_forwarder.go internal/upf/
go build ./cmd/core/
```

### 2. Set Up Network Interfaces

```bash
sudo ~/ella-core-jetson/scripts/setup-ella-net.sh
```

This creates:
- `ella-n3` veth pair (10.3.0.2 ↔ 10.3.0.1) for N2/N3
- `ella-n6` dummy interface for N6 (internet)
- NAT rule for UE traffic (10.45.0.0/16)

### 3. Start Ella Core

```bash
sudo ~/ella-core/core -config ~/ella-core-jetson/configs/ella-core.yaml
```

### 4. Configure via REST API

```bash
API="https://127.0.0.1:5002/api/v1"

# Initialize (first time only)
curl -sk -X POST $API/init -H "Content-Type: application/json" \
  -d '{"email":"admin@dtc.io","password":"EllaTest2024!"}'

# Login
TOKEN=$(curl -sk -X POST $API/auth/login -H "Content-Type: application/json" \
  -d '{"email":"admin@dtc.io","password":"EllaTest2024!"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['token'])")

# Set PLMN
curl -sk -X PUT $API/operator/id -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -d '{"mcc":"001","mnc":"01"}'

# Set TAC
curl -sk -X PUT $API/operator/tracking -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -d '{"supportedTacs":["000001"]}'

# Set Operator Code (OPc)
curl -sk -X PUT $API/operator/code -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"operatorCode":"1185B494BDAC5B7909DEE705B017F165"}'

# Add subscriber
curl -sk -X POST $API/subscribers -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"imsi":"001010123456789","key":"96d2e48ab066384d0c61828f2b2fe5e3","opc":"1185b494bdac5b7909dee705b017f165","sequenceNumber":"000000000022","profile_name":"default"}'
```

### 5. Connect a gNB

**UERANSIM (fastest — no PHY):**
```bash
sudo ~/UERANSIM/build/nr-gnb -c ~/ella-core-jetson/configs/ueransim_gnb_ella.yaml
sudo ~/UERANSIM/build/nr-ue -c ~/ella-core-jetson/configs/ueransim_ue_ella.yaml
```

**OAI rfsim (full PHY):**
```bash
sudo nr-softmodem -O ~/ella-core-jetson/configs/gnb_oai_rfsim_ella.conf --rfsim
sudo nr-uesoftmodem -O ~/ella-core-jetson/configs/oai_nrue_rfsim_ella.conf \
  --rfsim --numerology 1 -r 106 --band 78 -C 3319680000 --ssb 516 --ue-fo-compensation
```

**srsRAN (ZMQ):**
```bash
sudo gnb -c ~/ella-core-jetson/configs/gnb_cpu_zmq_ella.yaml
```

## Network Architecture

```
┌──────────────────────────────────────────────────────────┐
│                    Jetson AGX Orin                         │
│                                                           │
│  ┌─────────────┐     NGAP/SCTP      ┌────────────────┐  │
│  │   gNB       │◄──────────────────►│   Ella Core    │  │
│  │ (10.3.0.1)  │     GTP-U/UDP      │  (10.3.0.2)   │  │
│  │             │◄──────────────────►│                │  │
│  └─────────────┘    ella-n3-peer     │  AMF+SMF+UPF  │  │
│        │                ella-n3      │   (1 binary)   │  │
│        │                             └───────┬────────┘  │
│   ZMQ / rfsim                                │ ellatun   │
│        │                                     │ 10.45.0.1 │
│  ┌─────────────┐                             │           │
│  │     UE      │                        ella-n6 (N6)     │
│  │             │                             │           │
│  └─────────────┘                        NAT → internet   │
└──────────────────────────────────────────────────────────┘
```

## Footprint Comparison

| Metric | Ella Core | Open5GS |
|--------|-----------|---------|
| Processes | 1 | 17 + MongoDB |
| RAM (idle) | 37 MB | 873 MB |
| Binary size | 50 MB | ~200 MB (all NFs) |
| Database | Embedded SQLite | MongoDB 7.0 |
| Config | 1 YAML + REST API | 11 YAML files |
| Startup time | ~2 seconds | ~10 seconds |

## Kernel Compatibility

| Kernel | eBPF UPF (native) | Userspace UPF (patched) |
|--------|-------------------|-------------------------|
| 6.8+ | ✅ Full performance (XDP) | ✅ Works (unused) |
| 5.15–6.7 | ❌ BPF helper missing | ✅ Falls back automatically |
| 5.4–5.14 | ❌ | ✅ Should work (untested) |

## Test Results Summary

| Test | Status | Notes |
|------|--------|-------|
| NGAP: srsRAN gNB → AMF | ✅ | NGSetup OK, PLMN/TAC matched |
| NGAP: OAI gNB → AMF | ✅ | NGSetup OK |
| NGAP: UERANSIM gNB → AMF | ✅ | NGSetup OK |
| NAS Registration (UERANSIM) | ✅ | Auth + Security Mode + Accept |
| PDU Session (UERANSIM) | ✅ | IP 10.45.0.1 assigned |
| Full PHY E2E (OAI rfsim) | ✅ | PSS→MIB→SIB1→RACH→RRC→NAS→PDU |
| UE IP assignment | ✅ | 10.45.0.1 from 10.45.0.0/22 pool |

## How the Userspace UPF Works

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for details.

**TL;DR:** When the eBPF XDP program fails to load (kernel too old), Ella Core falls back to:
1. Creating BPF hash/array maps in the kernel (works on 5.4+)
2. Skipping XDP attachment
3. Starting a goroutine-based GTP-U forwarder that:
   - Listens on UDP 2152 (N3)
   - Decapsulates GTP-U, looks up TEID in BPF map for PDR
   - Forwards inner IP packet to TUN device (`ellatun`)
   - Reads from TUN, looks up UE IP for downlink PDR
   - Encapsulates in GTP-U and sends to gNB

## License

- Ella Core: Apache-2.0 (https://github.com/ellanetworks/core)
- Patches in this repo: Apache-2.0
