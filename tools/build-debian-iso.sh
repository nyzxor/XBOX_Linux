#!/bin/bash
#
# build-debian-iso.sh - Build a minimal Debian Live ISO for V86/Halfix
#
# Creates a bootable ISO with a minimal Debian system that can be loaded
# directly as a CD-ROM in V86 or Halfix emulators.
# This is the RECOMMENDED approach for Xbox deployment since ISOs are
# easier to package than raw disk images.
#
# Requirements: debootstrap, xorriso, isolinux, syslinux-common,
#               squashfs-tools, mtools
#
# Usage: sudo ./build-debian-iso.sh [output_dir]
#

set -euo pipefail

DEBIAN_RELEASE="bookworm"
DEBIAN_ARCH="i386"
DEBIAN_MIRROR="http://deb.debian.org/debian"
ISO_NAME="debian-xbox.iso"
OUTPUT_DIR="${1:-$(pwd)}"
WORK_DIR="/tmp/debian-iso-build"
ROOTFS="${WORK_DIR}/rootfs"
ISO_DIR="${WORK_DIR}/iso"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[-]${NC} $1"; exit 1; }

cleanup() {
    log "Cleaning up..."
    umount -lf "${ROOTFS}/proc" 2>/dev/null || true
    umount -lf "${ROOTFS}/sys" 2>/dev/null || true
    umount -lf "${ROOTFS}/dev/pts" 2>/dev/null || true
    umount -lf "${ROOTFS}/dev" 2>/dev/null || true
    rm -rf "${WORK_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

for cmd in debootstrap xorriso mksquashfs; do
    command -v "$cmd" &>/dev/null || error "Missing: $cmd (apt install debootstrap xorriso squashfs-tools)"
done

[ "$(id -u)" -ne 0 ] && error "Run as root (sudo)"

log "=== Debian Live ISO Builder for Xbox Emulators ==="

rm -rf "${WORK_DIR}"
mkdir -p "${ROOTFS}" "${ISO_DIR}/live" "${ISO_DIR}/isolinux"

# Step 1: Debootstrap minimal system
log "Debootstrapping ${DEBIAN_RELEASE} ${DEBIAN_ARCH}..."
debootstrap --arch="${DEBIAN_ARCH}" \
    --variant=minbase \
    --include=linux-image-686,live-boot,systemd,systemd-sysv,\
udev,dbus,ifupdown,iproute2,iputils-ping,nano,less,\
procps,sudo,bash-completion,locales,net-tools,\
pciutils,usbutils,htop,tmux,wget,curl,ca-certificates \
    "${DEBIAN_RELEASE}" "${ROOTFS}" "${DEBIAN_MIRROR}"

# Step 2: Configure inside chroot
mount --bind /dev "${ROOTFS}/dev"
mount --bind /dev/pts "${ROOTFS}/dev/pts"
mount -t proc proc "${ROOTFS}/proc"
mount -t sysfs sys "${ROOTFS}/sys"

chroot "${ROOTFS}" /bin/bash << 'CHROOT'
set -e

# Users
echo "root:xbox" | chpasswd
useradd -m -s /bin/bash -G sudo xbox
echo "xbox:xbox" | chpasswd

# Auto-login on serial console
mkdir -p /etc/systemd/system/serial-getty@ttyS0.service.d
cat > /etc/systemd/system/serial-getty@ttyS0.service.d/override.conf << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin xbox --noclear %I 115200 linux
EOF
systemctl enable serial-getty@ttyS0.service

# Auto-login on tty1 (VGA console)
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/override.conf << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin xbox --noclear %I $TERM
EOF

# Disable heavy services
systemctl disable apt-daily.timer 2>/dev/null || true
systemctl disable apt-daily-upgrade.timer 2>/dev/null || true
systemctl mask systemd-timesyncd.service 2>/dev/null || true

# Locale
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf

# Hostname
echo "debian-xbox" > /etc/hostname

# Network
cat > /etc/network/interfaces << 'NET'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
NET

# Performance tuning for emulated environment
cat > /etc/sysctl.d/99-v86.conf << 'SYSCTL'
vm.swappiness=10
vm.dirty_ratio=40
kernel.printk=3 4 1 3
net.ipv6.conf.all.disable_ipv6=1
SYSCTL

# Welcome message
cat > /etc/motd << 'MOTD'

  ____       _     _                __  ______
 |  _ \  ___| |__ (_) __ _ _ __    \ \/ / __ )  _____  __
 | | | |/ _ \ '_ \| |/ _` | '_ \   \  /|  _ \ / _ \ \/ /
 | |_| |  __/ |_) | | (_| | | | |  /  \| |_) | (_) >  <
 |____/ \___|_.__/|_|\__,_|_| |_| /_/\_\____/ \___/_/\_\

 Debian for Xbox Linux Emulator
 User: xbox / Password: xbox
 Root: root / Password: xbox

MOTD

# Cleanup
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
CHROOT

umount -lf "${ROOTFS}/proc" "${ROOTFS}/sys" "${ROOTFS}/dev/pts" "${ROOTFS}/dev"

# Step 3: Copy kernel and initramfs to ISO
log "Preparing ISO boot files..."
VMLINUZ=$(ls "${ROOTFS}/boot/vmlinuz-"* | head -1)
INITRD=$(ls "${ROOTFS}/boot/initrd.img-"* | head -1)

cp "$VMLINUZ" "${ISO_DIR}/live/vmlinuz"
cp "$INITRD" "${ISO_DIR}/live/initrd.img"

# Step 4: Create squashfs
log "Creating squashfs (this takes a while)..."
mksquashfs "${ROOTFS}" "${ISO_DIR}/live/filesystem.squashfs" \
    -comp xz -Xbcj x86 -b 256K -no-duplicates

# Step 5: Create isolinux config
ISOLINUX_DIR="/usr/lib/ISOLINUX"
SYSLINUX_DIR="/usr/lib/syslinux/modules/bios"

[ -f "${ISOLINUX_DIR}/isolinux.bin" ] || ISOLINUX_DIR="/usr/share/syslinux"
[ -f "${SYSLINUX_DIR}/ldlinux.c32" ] || SYSLINUX_DIR="/usr/share/syslinux"

cp "${ISOLINUX_DIR}/isolinux.bin" "${ISO_DIR}/isolinux/"
cp "${SYSLINUX_DIR}/ldlinux.c32" "${ISO_DIR}/isolinux/" 2>/dev/null || true
cp "${SYSLINUX_DIR}/libutil.c32" "${ISO_DIR}/isolinux/" 2>/dev/null || true
cp "${SYSLINUX_DIR}/menu.c32" "${ISO_DIR}/isolinux/" 2>/dev/null || true

cat > "${ISO_DIR}/isolinux/isolinux.cfg" << 'ISOLINUX'
UI menu.c32
PROMPT 0
TIMEOUT 30
DEFAULT debian

MENU TITLE Debian Xbox Linux

LABEL debian
    MENU LABEL Debian (VGA Console)
    KERNEL /live/vmlinuz
    INITRD /live/initrd.img
    APPEND boot=live toram net.ifnames=0 nomodeset quiet

LABEL debian-serial
    MENU LABEL Debian (Serial Console)
    KERNEL /live/vmlinuz
    INITRD /live/initrd.img
    APPEND boot=live toram console=ttyS0,115200n8 net.ifnames=0 nomodeset quiet

LABEL debian-text
    MENU LABEL Debian (Text Only - Low RAM)
    KERNEL /live/vmlinuz
    INITRD /live/initrd.img
    APPEND boot=live toram net.ifnames=0 nomodeset systemd.unit=multi-user.target quiet
ISOLINUX

# Step 6: Build ISO
log "Building ISO..."
xorriso -as mkisofs \
    -o "${OUTPUT_DIR}/${ISO_NAME}" \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin 2>/dev/null || true \
    -c isolinux/boot.cat \
    -b isolinux/isolinux.bin \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    "${ISO_DIR}"

log "=== ISO Build Complete ==="
log "Output: ${OUTPUT_DIR}/${ISO_NAME}"
log "Size: $(du -h "${OUTPUT_DIR}/${ISO_NAME}" | cut -f1)"
log ""
log "Test with QEMU:"
log "  qemu-system-i386 -m 512 -cdrom ${OUTPUT_DIR}/${ISO_NAME} -serial stdio"
log ""
log "Copy to uwp/XboxLinux/Virtual_Machines5/disc.iso to use in Xbox emulator"
