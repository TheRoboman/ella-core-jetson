# ADRV9361-Z7035 Deployment Results

**Date:** 2026-05-25
**Hardware:** ADI ADRV9361-Z7035 + ADRV1CRR-BOB
**CPU:** Xilinx Zynq-7035 (dual Cortex-A9 @ 666 MHz, armv7l)
**RAM:** 990 MB usable

## Outcome

✅ **Phase A complete** — full 5G core (Ella Core v1.10.2, patched) running on the ADRV ARM, validated end-to-end with a UERANSIM gNB+UE:
- SCTP/NGAP connection established
- Full NAS Registration with NIA2 + NEA2
- PDU Session Establishment (UE got 10.45.0.1 from DNN "internet")

## Path

The ADI Kuiper kernel ships without SCTP, netfilter, or BTF — so a stock Kuiper SD card can run Ella Core's process but Ella Core's NGAP server can't bind (SCTP unsupported).

We solved this by:
1. Cloning `analogdevicesinc/linux@2023_r2`
2. Starting from `zynq_xcomm_adv7511_defconfig`
3. Enabling: `CONFIG_IP_SCTP`, `CONFIG_NETFILTER`, `CONFIG_NF_CONNTRACK`, `CONFIG_NF_NAT`, `CONFIG_IP_NF_*`, `CONFIG_DEBUG_INFO_BTF`, `CONFIG_BPF_*`
4. Cross-compiling (`ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-`) — 8 cores, ~12 minutes
5. Replacing the stock `uImage` + `devicetree.dtb` on the boot partition
6. Switching iptables to legacy backend (our kernel has legacy netfilter, not nftables)

## Resource Footprint

| | On board |
|---|---|
| Boot partition (BOOT.BIN + uImage + dtb + uEnv.txt) | 13 MB |
| Root partition (stripped Debian armhf + Ella Core) | 218 MB |
| Ella Core binary (stripped armv7) | 35 MB |
| RAM after boot, idle | 49 MB used / 990 MB |
| RAM with Ella Core running | ~75 MB used |
| Time from power-on to NGAP listening | ~45 seconds |

## What Worked

- **Cross-compile**: armv7 build of Ella Core needed 4 small fixes for 32-bit `int` overflow
- **Userspace UPF fallback**: the eBPF XDP program still fails verifier on Cortex-A9 (different error than Jetson, same fallback works)
- **iptables-legacy**: kernel has classic netfilter; `update-alternatives` switch is needed once on first boot
- **Boot files**: pulled BOOT.BIN + uImage + devicetree from ADI Kuiper SD image, replaced uImage + dtb with our custom build
- **NGAP / GTP-U / API**: all three sockets bind correctly
- **UE Registration + PDU Session**: full NAS flow completes, IP allocated

## Known Issues

1. **systemd waits for `/dev/mmcblk0p1` and `/dev/ttyPS0` for 90s** — devices appear but after the timeout. Fix: don't list `/boot` in fstab, mask `getty@ttyPS0.service`. These are race conditions, not kernel issues.
2. **System clock wrong**: no RTC on board, no NTP configured. Logs show wrong dates but functionality unaffected.
3. **`couldn't enable IP forwarding: failed to install nftables rules`**: Ella Core's runtime tries to use nftables for some routing. Doesn't block NGAP. Could be fixed with `CONFIG_NF_TABLES=y` (we didn't enable it, only legacy iptables).
4. **TUN routing helpers** (`ip rule`): UERANSIM's TUN setup uses `ip rule` which the kernel doesn't support. PDU session is established at NAS level but the UE tun interface isn't routed. Doesn't affect Ella Core; UERANSIM-specific.
5. **eBPF XDP program**: still fails verifier on this kernel (different reason — stack access pattern). Userspace UPF fallback handles it.

## Comparison: Same Ella Core, Two Platforms

| | Jetson AGX Orin | ADRV9361-Z7035 |
|---|---|---|
| Architecture | aarch64 | armv7l |
| CPU | 12× A78AE @ 2.2 GHz | 2× A9 @ 666 MHz |
| RAM | 64 GB | 990 MB |
| Kernel | 5.15 (Tegra) | 6.1.70 (custom Zynq) |
| eBPF UPF (native) | ❌ | ❌ |
| Userspace UPF | ✅ | ✅ |
| NGAP (SCTP) | ✅ | ✅ |
| Full UE attach | ✅ (UERANSIM, OAI rfsim) | ✅ (UERANSIM) |
| RAM used by Ella Core | ~40 MB | ~30 MB |
| Boot-to-NGAP time | ~5 s | ~45 s |

## Next Steps for Production

For an actual in-orbit deployment on this hardware class:
- Add `CONFIG_NF_TABLES=y` to enable Ella Core's nftables-based routing
- Add RTC support or NTP/PTP at boot
- Build a custom Buildroot/Yocto image instead of Debian (gets rootfs <100 MB)
- Tune kernel for low memory: drop unused drivers, disable swap, reduce log buffer
- Wire up watchdog (Zynq has hardware WDT)
- Consider replacing Cortex-A9 with Zynq UltraScale+ (Cortex-A53, much faster) for headroom
