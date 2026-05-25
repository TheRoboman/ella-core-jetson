#!/bin/bash
# Deploy a custom-built Zynq kernel to the SD card's boot partition
# Run AFTER build-kernel.sh has produced uImage + dtb in the build dir.
#
# Usage: SD_BOOT_DEV=/dev/sdb1 SD_ROOT_DEV=/dev/sdb2 sudo ./deploy-kernel.sh

set -euo pipefail

KBUILD_OUTPUT="${KBUILD_OUTPUT:-${HOME}/adi-linux-build}"
SD_BOOT_DEV="${SD_BOOT_DEV:-/dev/sdb1}"
SD_ROOT_DEV="${SD_ROOT_DEV:-/dev/sdb2}"
KSRC="${KSRC:-${HOME}/adi-linux}"

[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }
[[ -f "$KBUILD_OUTPUT/arch/arm/boot/uImage" ]] || { echo "uImage missing - build first"; exit 1; }
[[ -f "$KBUILD_OUTPUT/arch/arm/boot/dts/zynq-adrv9361-z7035-bob.dtb" ]] || { echo "DTB missing"; exit 1; }
[[ -b "$SD_BOOT_DEV" ]] || { echo "$SD_BOOT_DEV not a block device"; exit 1; }
[[ -b "$SD_ROOT_DEV" ]] || { echo "$SD_ROOT_DEV not a block device"; exit 1; }

echo "==> Mounting SD card boot partition"
mkdir -p /tmp/sd_boot /tmp/sd_root
mount "$SD_BOOT_DEV" /tmp/sd_boot
mount "$SD_ROOT_DEV" /tmp/sd_root

echo "==> Backing up existing kernel"
[[ -f /tmp/sd_boot/uImage.old ]] && rm /tmp/sd_boot/uImage.old
[[ -f /tmp/sd_boot/devicetree.dtb.old ]] && rm /tmp/sd_boot/devicetree.dtb.old
cp /tmp/sd_boot/uImage /tmp/sd_boot/uImage.old
cp /tmp/sd_boot/devicetree.dtb /tmp/sd_boot/devicetree.dtb.old

echo "==> Installing new kernel + DTB"
cp "$KBUILD_OUTPUT/arch/arm/boot/uImage" /tmp/sd_boot/uImage
cp "$KBUILD_OUTPUT/arch/arm/boot/dts/zynq-adrv9361-z7035-bob.dtb" /tmp/sd_boot/devicetree.dtb

# Install kernel modules (if any were built - SCTP/netfilter built-in so probably none needed)
if [[ -d "$KBUILD_OUTPUT/lib/modules" ]] || [[ -n "$(find $KSRC -name '*.ko' 2>/dev/null | head -1)" ]]; then
    echo "==> Installing kernel modules"
    cd "$KSRC"
    make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- KBUILD_OUTPUT="$KBUILD_OUTPUT" \
        INSTALL_MOD_PATH=/tmp/sd_root modules_install
fi

sync
echo "==> New kernel installed:"
ls -lh /tmp/sd_boot/uImage /tmp/sd_boot/devicetree.dtb

umount /tmp/sd_boot && rmdir /tmp/sd_boot
umount /tmp/sd_root && rmdir /tmp/sd_root
echo "==> Done. Insert SD into board and boot."
