#!/bin/bash
# Build a minimal Debian armhf SD card for ADRV9361-Z7035 with Ella Core 5G
#
# Output: bootable SD card with stripped Debian + Ella Core (~230 MB rootfs)
# Source: ADI Kuiper image (3.5 GB download for ~13 MB of boot files)
#
# Usage:
#   1. Plug your SD card in via USB
#   2. Edit SD_DEVICE below to match (check with `lsblk`)
#   3. Run: sudo ./build-sd-card.sh
#
# Requires: debootstrap, qemu-user-static, gcc-arm-linux-gnueabihf,
#           u-boot-tools, parted, curl, unzip

set -euo pipefail

SD_DEVICE="${SD_DEVICE:-/dev/sdb}"  # OVERRIDE BEFORE RUNNING
KUIPER_URL="https://swdownloads.analog.com/cse/kuiper/image_2025-03-18-ADI-Kuiper-full.zip"
KUIPER_DIR="${HOME}/kuiper-image"
ELLA_CORE_BIN="${ELLA_CORE_BIN:-${HOME}/ella-core/core-armv7}"

# ---- safety checks ----
[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)"; exit 1; }
[[ -b "$SD_DEVICE" ]] || { echo "$SD_DEVICE is not a block device"; exit 1; }
[[ -f "$ELLA_CORE_BIN" ]] || { echo "Cross-compile ella-core first: see README"; exit 1; }

size_gb=$(($(blockdev --getsize64 "$SD_DEVICE") / 1024 / 1024 / 1024))
if (( size_gb < 4 )); then
    echo "SD card too small ($size_gb GB)"; exit 1
fi
if (( size_gb > 128 )); then
    echo "Warning: $SD_DEVICE is $size_gb GB — really a small SD card and not a disk?"
    read -p "Type YES to continue: " confirm
    [[ "$confirm" == "YES" ]] || exit 1
fi

echo "==> Will wipe $SD_DEVICE ($size_gb GB) in 5 seconds. Ctrl-C to abort."
sleep 5

# ---- step 1: wipe ----
echo "==> Wiping partition table"
umount "${SD_DEVICE}"* 2>/dev/null || true
dd if=/dev/zero of="$SD_DEVICE" bs=1M count=100 status=none
dd if=/dev/zero of="$SD_DEVICE" bs=1M seek=$((size_gb * 1024 - 20)) count=20 status=none
sync

# ---- step 2: partition ----
echo "==> Creating partitions (FAT32 boot 256MB + ext4 root rest)"
parted -s "$SD_DEVICE" \
    mklabel msdos \
    mkpart primary fat32 1MiB 256MiB \
    mkpart primary ext4 256MiB 100% \
    set 1 boot on \
    set 1 lba on
partprobe "$SD_DEVICE"
sleep 1

mkfs.vfat -F 32 -n BOOT "${SD_DEVICE}1"
mkfs.ext4 -L rootfs -F "${SD_DEVICE}2"

# ---- step 3: download Kuiper for boot files ----
mkdir -p "$KUIPER_DIR"
if [[ ! -f "$KUIPER_DIR/kuiper.img" ]]; then
    echo "==> Downloading ADI Kuiper image (~3.5 GB)"
    curl -L --progress-bar -o "$KUIPER_DIR/kuiper.zip" "$KUIPER_URL"
    echo "==> Extracting .img"
    cd "$KUIPER_DIR" && unzip -o kuiper.zip && rm kuiper.zip
    mv "$KUIPER_DIR"/*.img "$KUIPER_DIR/kuiper.img"
fi

# ---- step 4: extract boot files ----
echo "==> Extracting boot files from Kuiper"
mkdir -p /tmp/kuiper_boot
boot_off=$((24576 * 512))
boot_size=$((4194304 * 512))
mount -o ro,loop,offset=$boot_off,sizelimit=$boot_size "$KUIPER_DIR/kuiper.img" /tmp/kuiper_boot

mkdir -p /tmp/sd_boot
mount "${SD_DEVICE}1" /tmp/sd_boot
cp /tmp/kuiper_boot/zynq-adrv9361-z7035-bob/cmos/BOOT.BIN /tmp/sd_boot/
cp /tmp/kuiper_boot/zynq-adrv9361-z7035-bob/cmos/devicetree.dtb /tmp/sd_boot/
cp /tmp/kuiper_boot/zynq-common/uImage /tmp/sd_boot/

cat > /tmp/sd_boot/uEnv.txt <<'EOF'
kernel_image=uImage
devicetree_image=devicetree.dtb
uenvcmd=run adi_sdboot
adi_sdboot=echo Copying Linux from SD to RAM... && fatload mmc 0 0x3000000 ${kernel_image} && fatload mmc 0 0x2A00000 ${devicetree_image} && bootm 0x3000000 - 0x2A00000
bootargs=console=ttyPS0,115200 root=/dev/mmcblk0p2 rw earlycon rootfstype=ext4 rootwait clk_ignore_unused cpuidle.off=1
EOF

umount /tmp/kuiper_boot
rmdir /tmp/kuiper_boot

# ---- step 5: debootstrap minimal Debian ----
echo "==> Building minimal Debian armhf rootfs"
mkdir -p /tmp/sd_root
mount "${SD_DEVICE}2" /tmp/sd_root

debootstrap --foreign --arch=armhf --variant=minbase \
    --include=openssh-server,iproute2,iptables,ifupdown,isc-dhcp-client,sudo,vim-tiny,curl,ca-certificates,libc6,kmod \
    bookworm /tmp/sd_root http://deb.debian.org/debian/

cp /usr/bin/qemu-arm-static /tmp/sd_root/usr/bin/
chroot /tmp/sd_root /debootstrap/debootstrap --second-stage

# Install init system inside chroot
cp /etc/resolv.conf /tmp/sd_root/etc/resolv.conf
chroot /tmp/sd_root /usr/bin/apt-get update
chroot /tmp/sd_root /usr/bin/apt-get install -y --no-install-recommends systemd-sysv kbd

# ---- step 6: configure rootfs ----
echo "==> Configuring rootfs"
echo "adrv5gc" > /tmp/sd_root/etc/hostname

cat > /tmp/sd_root/etc/hosts <<'EOF'
127.0.0.1   localhost
127.0.1.1   adrv5gc
::1         localhost ip6-localhost ip6-loopback
EOF

cat > /tmp/sd_root/etc/fstab <<'EOF'
/dev/mmcblk0p2  /        ext4   defaults,noatime  0  1
# Note: /dev/mmcblk0p1 (boot) intentionally not mounted at runtime —
# the Zynq SD controller's udev event for p1 races with systemd's wait,
# causing a 90s boot hang. U-Boot reads the boot partition before kernel
# starts, so we don't need it mounted later.
proc            /proc    proc   defaults          0  0
EOF

mkdir -p /tmp/sd_root/etc/network/interfaces.d
cat > /tmp/sd_root/etc/network/interfaces.d/eth0 <<'EOF'
auto eth0
iface eth0 inet static
    address 169.254.237.42
    netmask 255.255.0.0
EOF

cat > /tmp/sd_root/etc/network/interfaces <<'EOF'
auto lo
iface lo inet loopback
source /etc/network/interfaces.d/*
EOF

# Root password = analog (matches standard ADI Kuiper)
chroot /tmp/sd_root /bin/bash -c "echo 'root:analog' | chpasswd"

# Enable root SSH (lock down after first boot if desired)
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /tmp/sd_root/etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /tmp/sd_root/etc/ssh/sshd_config

# Pre-generate SSH host keys
chroot /tmp/sd_root /usr/bin/ssh-keygen -A
chroot /tmp/sd_root /bin/systemctl enable ssh

# Switch iptables to legacy (our custom Zynq kernel has classic netfilter, not nftables)
# Debian 12 defaults to nftables backend.
chroot /tmp/sd_root /usr/sbin/update-alternatives --set iptables /usr/sbin/iptables-legacy 2>/dev/null || true
chroot /tmp/sd_root /usr/sbin/update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy 2>/dev/null || true

# Mask getty@ttyPS0 to avoid 90s boot delay (race: device shows up after timeout)
chroot /tmp/sd_root /bin/systemctl mask getty@ttyPS0.service 2>/dev/null || true

# ---- step 7: install Ella Core ----
echo "==> Installing Ella Core armv7"
mkdir -p /tmp/sd_root/opt/ella-core/data
cp "$ELLA_CORE_BIN" /tmp/sd_root/opt/ella-core/core
arm-linux-gnueabihf-strip /tmp/sd_root/opt/ella-core/core

# Generate self-signed cert for API HTTPS
openssl req -new -x509 -days 3650 -nodes \
    -out /tmp/sd_root/opt/ella-core/cert.pem \
    -keyout /tmp/sd_root/opt/ella-core/key.pem \
    -subj "/CN=adrv5gc" 2>/dev/null

cat > /tmp/sd_root/opt/ella-core/core.yaml <<'EOF'
logging:
  system:
    level: "info"
    output: "stdout"
  audit:
    output: "stdout"
db:
  path: "/opt/ella-core/data/ella.db"
interfaces:
  n2:
    address: "169.254.237.42"
    port: 38412
  n3:
    name: "eth0"
  n6:
    name: "eth0"
  api:
    address: "0.0.0.0"
    port: 5002
    tls:
      cert: "/opt/ella-core/cert.pem"
      key: "/opt/ella-core/key.pem"
xdp:
  attach-mode: "generic"
telemetry:
  enabled: false
EOF

cat > /tmp/sd_root/opt/ella-core/setup-net.sh <<'EOF'
#!/bin/bash
# Best-effort: ip_forward + NAT for UE traffic. If iptables fails (kernel
# missing netfilter), don't block service startup — Ella Core still works
# as a control-plane only.
sysctl -w net.ipv4.ip_forward=1
if ! iptables -t nat -C POSTROUTING -s 10.45.0.0/16 ! -o ellatun -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -s 10.45.0.0/16 ! -o ellatun -j MASQUERADE 2>/dev/null || \
        echo "WARNING: iptables NAT unavailable (kernel without netfilter) — UE-to-internet routing disabled"
fi
exit 0
EOF
chmod +x /tmp/sd_root/opt/ella-core/setup-net.sh

cat > /tmp/sd_root/etc/systemd/system/ella-core.service <<'EOF'
[Unit]
Description=Ella Core 5G Core Network
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/ella-core
ExecStartPre=/opt/ella-core/setup-net.sh
ExecStart=/opt/ella-core/core -config /opt/ella-core/core.yaml
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
chroot /tmp/sd_root /bin/systemctl enable ella-core

# ---- step 8: strip bloat ----
echo "==> Stripping bloat"
chroot /tmp/sd_root /usr/bin/apt-get clean
rm -rf /tmp/sd_root/var/cache/apt/archives/*.deb
rm -rf /tmp/sd_root/usr/share/man/*
rm -rf /tmp/sd_root/usr/share/doc/*
rm -rf /tmp/sd_root/usr/share/info/*
rm -rf /tmp/sd_root/var/lib/apt/lists/*
rm -f /tmp/sd_root/usr/bin/qemu-arm-static

# ---- step 9: cleanup ----
echo "==> Final size:"
du -sh /tmp/sd_root

sync
umount /tmp/sd_boot && rmdir /tmp/sd_boot
umount /tmp/sd_root && rmdir /tmp/sd_root

echo "==> Done. SD card ready. Insert into ADRV1CRR-BOB and boot."
echo "    First boot: connect UART (115200 baud, /dev/ttyUSB0)"
echo "    SSH: root@169.254.237.42 (password: analog)"
echo "    API: https://169.254.237.42:5002"
