#!/bin/bash
# Build a custom Zynq kernel for ADRV9361-Z7035 with networking features needed
# for Ella Core 5G: SCTP (NGAP), netfilter (NAT), BTF (eBPF type info).
#
# Output: $KBUILD_OUTPUT/arch/arm/boot/{uImage, dts/zynq-adrv9361-z7035-bob.dtb}
#
# Usage:
#   git clone --depth=1 --branch 2023_r2 https://github.com/analogdevicesinc/linux ~/adi-linux
#   ./build-kernel.sh

set -euo pipefail

KSRC="${KSRC:-${HOME}/adi-linux}"
KBUILD_OUTPUT="${KBUILD_OUTPUT:-${HOME}/adi-linux-build}"
JOBS="${JOBS:-$(nproc)}"

[[ -d "$KSRC" ]] || { echo "Kernel source not at $KSRC - clone analogdevicesinc/linux first"; exit 1; }
which arm-linux-gnueabihf-gcc > /dev/null || { echo "install gcc-arm-linux-gnueabihf"; exit 1; }
which mkimage > /dev/null || { echo "install u-boot-tools"; exit 1; }

export ARCH=arm
export CROSS_COMPILE=arm-linux-gnueabihf-
export KBUILD_OUTPUT
mkdir -p "$KBUILD_OUTPUT"

cd "$KSRC"

echo "==> Applying zynq_xcomm_adv7511_defconfig"
make zynq_xcomm_adv7511_defconfig

echo "==> Enabling 5G core features"
CFG=./scripts/config
$CFG --file "$KBUILD_OUTPUT/.config" -e IP_SCTP

# Netfilter framework + iptables NAT
$CFG --file "$KBUILD_OUTPUT/.config" -e NETFILTER
$CFG --file "$KBUILD_OUTPUT/.config" -e NETFILTER_ADVANCED
$CFG --file "$KBUILD_OUTPUT/.config" -e NF_CONNTRACK
$CFG --file "$KBUILD_OUTPUT/.config" -e NF_NAT
$CFG --file "$KBUILD_OUTPUT/.config" -e IP_NF_IPTABLES
$CFG --file "$KBUILD_OUTPUT/.config" -e IP_NF_FILTER
$CFG --file "$KBUILD_OUTPUT/.config" -e IP_NF_NAT
$CFG --file "$KBUILD_OUTPUT/.config" -e IP_NF_TARGET_MASQUERADE
$CFG --file "$KBUILD_OUTPUT/.config" -e NETFILTER_XT_MATCH_CONNTRACK

# BPF / BTF (requires `pahole` from `dwarves` package at build time)
$CFG --file "$KBUILD_OUTPUT/.config" -e BPF_SYSCALL
$CFG --file "$KBUILD_OUTPUT/.config" -e BPF_JIT
$CFG --file "$KBUILD_OUTPUT/.config" -e DEBUG_INFO
$CFG --file "$KBUILD_OUTPUT/.config" -e DEBUG_INFO_DWARF5
$CFG --file "$KBUILD_OUTPUT/.config" -e DEBUG_INFO_BTF
$CFG --file "$KBUILD_OUTPUT/.config" -e TUN

# Phase B (nFAPI L2/L3 on the board): tighter timing
$CFG --file "$KBUILD_OUTPUT/.config" -d HZ_100
$CFG --file "$KBUILD_OUTPUT/.config" -d HZ_PERIODIC
$CFG --file "$KBUILD_OUTPUT/.config" -e HZ_1000
$CFG --file "$KBUILD_OUTPUT/.config" --set-val HZ 1000
$CFG --file "$KBUILD_OUTPUT/.config" -e NO_HZ_FULL
$CFG --file "$KBUILD_OUTPUT/.config" -e NO_HZ_COMMON
$CFG --file "$KBUILD_OUTPUT/.config" -e RCU_NOCB_CPU
$CFG --file "$KBUILD_OUTPUT/.config" -e PREEMPT
# CONFIG_PREEMPT_RT not available on ARM in kernel 6.1 (mainlined in 6.12+).
# We rely on PREEMPT + isolcpus + SCHED_FIFO for OAI L2 timing.
$CFG --file "$KBUILD_OUTPUT/.config" -e CPU_FREQ_DEFAULT_GOV_PERFORMANCE
$CFG --file "$KBUILD_OUTPUT/.config" -d CPU_FREQ_DEFAULT_GOV_SCHEDUTIL

make olddefconfig

echo "==> Building kernel + DTB (jobs=$JOBS)"
make -j"$JOBS" LOADADDR=0x8000 uImage zynq-adrv9361-z7035-bob.dtb

echo ""
echo "==> Built:"
ls -lh "$KBUILD_OUTPUT/arch/arm/boot/uImage"
ls -lh "$KBUILD_OUTPUT/arch/arm/boot/dts/zynq-adrv9361-z7035-bob.dtb"
