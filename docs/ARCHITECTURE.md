# Userspace UPF Architecture

## Problem

Ella Core v1.10.2 uses an eBPF/XDP-based UPF for high-performance packet forwarding. The XDP program uses BPF helper function `bpf_dynptr_data` (func #189), introduced in Linux 5.19. The Jetson AGX Orin runs kernel 5.15.148-tegra, causing the BPF verifier to reject the program.

## Solution

We modified Ella Core to automatically fall back to a userspace GTP-U forwarder when the eBPF program fails to load. The control plane (AMF, SMF, session management) remains unchanged — only the data plane forwarding path differs.

## Modified Files

### `internal/upf/ebpf/objects.go`

The `Load()` method now:
1. Attempts full eBPF load (program + maps) — works on kernel 6.8+
2. On failure, sets `UserspaceMode = true`
3. Creates BPF maps individually from the spec (hash maps, arrays work on 5.4+)
4. Skips loading the XDP program

The BPF maps are still kernel-resident for two reasons:
- All existing stats/monitoring code (`stats.go`, `monitorUsage`) works unchanged
- PDR lookup from the forwarder uses the same `Lookup()` API as the XDP path

### `internal/upf/upf.go`

The `Start()` function now:
1. Checks `bpfObjects.UserspaceMode` before XDP attachment
2. Skips `link.AttachXDP()` and `ringbuf.NewReader()` in userspace mode
3. Starts `runUserspaceForwarder()` goroutine instead
4. Guards `Close()`, `ReloadNAT()`, `ReloadFlowAccounting()` for nil links

### `internal/upf/gtpu_forwarder.go` (new file)

Implements:
- **TUN device** (`ellatun`, 10.45.0.1/16) using `songgao/water` library
- **GTP-U listener** on UDP 2152 (N3 address)
- **Uplink path**: UDP recv → GTP-U decap → TEID lookup in BPF map → write to TUN
- **Downlink path**: TUN read → extract dest IP → PDR lookup in BPF map → GTP-U encap → UDP send to gNB
- **URR accounting**: increments per-CPU byte counters via BPF map for usage reporting

## Data Flow

### Native eBPF path (kernel 6.8+)
```
gNB ──GTP-U──► [NIC] ──XDP program──► [NIC] ──► Internet
                         (kernel)
```

### Userspace fallback path (kernel 5.15)
```
gNB ──GTP-U──► [UDP socket] ──goroutine──► [TUN: ellatun] ──► Internet
                  (userspace)     ▲
                                  │
                        BPF map lookup
                       (PDR/FAR/QER)
```

## Performance Characteristics

| Metric | eBPF/XDP (native) | Userspace forwarder |
|--------|-------------------|---------------------|
| Latency | <1 ms | ~2-5 ms (context switches) |
| Throughput | >10 Gbps | ~1-2 Gbps (limited by TUN) |
| CPU usage | Minimal (kernel path) | 1 core for forwarder |
| Suitability | Production, high-rate | Testing, low-rate links (LEO) |

For LEO satellite links (typically 50-200 Mbps), the userspace forwarder is more than adequate.

## Why Not Replace eBPF Maps Too?

We keep kernel BPF maps (instead of pure Go maps) because:
1. **Zero code changes** in session engine, stats, monitoring, reconciler
2. **Atomic operations** — BPF maps have built-in concurrency safety
3. **Easy upgrade** — when kernel is upgraded to 6.8+, just remove the fallback
4. **Per-CPU arrays** for URR counters work correctly for usage reporting

## Build Requirements

- Go 1.26.2+
- `github.com/songgao/water` (already in go.mod)
- `github.com/vishvananda/netlink` (already in go.mod)
- Linux kernel 5.4+ (for BPF map creation)
- `CAP_NET_ADMIN` / root (for TUN device and BPF maps)
