# Test Results — Ella Core on Jetson AGX Orin

**Date:** 2026-05-17  
**Platform:** NVIDIA Jetson AGX Orin 64GB, Ubuntu 22.04, kernel 5.15.148-tegra  
**Ella Core:** v1.10.2 + userspace UPF patch  
**Go:** 1.26.2 linux/arm64

## 1. Ella Core Startup

```
Userspace UPF mode: BPF maps created, XDP program skipped
Userspace UPF: skipping XDP attachment, will use GTP-U forwarder
TUN device ready: name=ellatun, cidr=10.45.0.1/16
Userspace GTP-U forwarder listening: addr=10.3.0.2:2152, tun=ellatun
NGAP server started: address=10.3.0.2:38412
API server started: scheme=https, address=0.0.0.0:5002
```

**Startup time:** ~2 seconds (including DB migrations on first run)  
**RSS after startup:** 37.4 MB

## 2. NGAP Validation — srsRAN gNB

**Config:** `configs/gnb_cpu_zmq_ella.yaml`

```
[CU-CP] N2: Connection to AMF on 10.3.0.2:38412 was established
[NGAP]  Tx PDU: NGSetupRequest
[NGAP]  Rx PDU: NGSetupResponse
[CU-CP] Connected to AMF. Supported PLMNs: 00101
```

**Ella Core log:**
```
Added a new radio: address=10.3.0.1:51330
NGSetupRequest received, TAI matched (001/01, TAC 000001)
NGSetupResponse sent
Radio completed NG Setup: name=srscucp01
```

**Result:** ✅ NGAP NG Setup successful

## 3. NGAP Validation — OAI gNB (rfsim)

**Config:** `configs/gnb_oai_rfsim_ella.conf`

```
[NGAP] Send NGSetupRequest to AMF
[NGAP] Supported PLMN 0: MCC=001 MNC=01
[NGAP] Received NGSetupResponse from AMF
[GNB_APP] Received NGAP_REGISTER_GNB_CNF: associated AMF 1
[HW] Running as server waiting opposite rfsimulators to connect
```

**Result:** ✅ NGAP NG Setup successful, cell transmitting PBCH

## 4. Full NAS Registration — UERANSIM

**Config:** `configs/ueransim_gnb_ella.yaml` + `configs/ueransim_ue_ella.yaml`

```
[sctp] SCTP connection established (10.3.0.2:38412)
[ngap] NG Setup procedure is successful
[nas]  Selected plmn[001/01]
[rrc]  Selected cell plmn[001/01] tac[1] category[SUITABLE]
[nas]  Sending Initial Registration
[rrc]  RRC connection established
[nas]  UE switches to state [CM-CONNECTED]
[nas]  Authentication Request received (SQN 000000000042)
[nas]  Security Mode Command received (integrity[2] ciphering[2])
[nas]  Registration accept received
[nas]  Initial Registration is successful
[nas]  PDU Session Establishment Accept received (PSI[1])
```

**Ella Core subscriber status:**
```json
{
  "registered": true,
  "cipheringAlgorithm": "NEA2",
  "integrityAlgorithm": "NIA2",
  "pdu_sessions": [{
    "pdu_session_id": 1,
    "status": "active",
    "ipv4Address": "10.45.0.1",
    "dnn": "internet"
  }]
}
```

**Result:** ✅ Full NAS registration + PDU session establishment

## 5. Full PHY E2E — OAI gNB + nrUE (rfsim)

**Config:** `configs/gnb_oai_rfsim_ella.conf` + `configs/oai_nrue_rfsim_ella.conf`

```
[PHY]    Initial sync successful, PCI: 0
[NR_RRC] SIB1 decoded
[NR_MAC] RA-Msg3 transmitted
[NR_MAC] 4-Step RA procedure succeeded. Contention Resolution is successful.
[NR_RRC] State = NR_RRC_CONNECTED
[NAS]    Received Registration Accept with result 3GPP
[NAS]    Received PDU Session Establishment Accept, UE IPv4: 10.45.0.1
[OIP]    TUN Interface oaitun_ue1 successfully configured, IPv4 10.45.0.1
```

**Full PHY attach timeline:**
1. PSS/SSS detection → cell sync
2. PBCH decode → MIB (SFN, SCS=30kHz, CORESET0=11)
3. SIB1 decode → system info
4. PRACH transmission → RAR received
5. Msg3 (RRC Setup Request) → Msg4 (contention resolution)
6. RRC Connected
7. NAS Registration Request → Authentication → Security Mode → Accept
8. PDU Session Establishment → IP 10.45.0.1

**Result:** ✅ Complete PHY-level 5G SA attach through Ella Core

## 6. Footprint Comparison

Measured simultaneously on the same Jetson:

| | Ella Core | Open5GS + MongoDB |
|---|---|---|
| Process count | 1 | 18 |
| Total RSS | 37.4 MB | 872.7 MB |
| Virtual memory | 2204 MB | N/A |
| Binary size | 50 MB | ~200 MB total |
| Config files | 1 YAML | 11 YAML + MongoDB |
| Startup time | ~2s | ~10s |
| **RAM reduction** | **23.3x** | baseline |

## 7. Known Limitations

1. **srsRAN ZMQ** — PHY initialization hangs (gNB build regression, affects Open5GS too)
2. **Data plane throughput** — untested with actual traffic (TUN-based forwarder)
3. **IPv6** — RA responder disabled (requires veth XDP program)
4. **NAT conntrack** — GC goroutine not started in userspace mode
5. **Flow accounting** — not started in userspace mode

## 8. Validated Interfaces

| Interface | Protocol | Port | Status |
|-----------|----------|------|--------|
| N2 (NGAP) | SCTP | 38412 | ✅ Working |
| N3 (GTP-U) | UDP | 2152 | ✅ Listener active |
| N4 (internal) | In-process | — | ✅ Session engine |
| API | HTTPS | 5002 | ✅ REST + WebUI |
| N6 (data) | TUN + NAT | — | ✅ TUN created |
