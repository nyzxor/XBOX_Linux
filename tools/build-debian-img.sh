#!/bin/bash
#
# build-debian-img.sh - Build a minimal Debian image for V86 emulator
#
# This script creates a lightweight Debian 12 (Bookworm) i386 disk image
# optimized for running inside the V86 JavaScript x86 emulator.
#
# Requirements: qemu-system-i386, qemu-img, debootstrap, parted, kpartx,
#               mount, chroot (run as root or with sudo)
#
# Usage: sudo ./build-debian-img.sh [output_dir]
#

set -euo pipefail

# Configuration
DEBIAN_RELEASE="bookworm"
DEBIAN_ARCH="i386"
DEBIAN_MIRROR="http://deb.debian.org/debian"
IMG_SIZE="2G"
IMG_NAME="debian-v86.img"
OUTPUT_DIR="${1:-$(pwd)}"
MOUNT_DIR="/tmp/debian-v86-mount"
LOOP_DEV=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[-]${NC} $1"; exit 1; }

cleanup() {
    log "Cleaning up..."
    sync 2>/dev/null || true
    umount -lf "${MOUNT_DIR}/proc" 2>/dev/null || true
    umount -lf "${MOUNT_DIR}/sys" 2>/dev/null || true
    umount -lf "${MOUNT_DIR}/dev/pts" 2>/dev/null || true
    umount -lf "${MOUNT_DIR}/dev" 2>/dev/null || true
    umount -lf "${MOUNT_DIR}" 2>/dev/null || true
    [ -n "$LOOP_DEV" ] && losetup -d "$LOOP_DEV" 2>/dev/null || true
    rm -rf "${MOUNT_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

# Check dependencies
for cmd in qemu-img debootstrap parted losetup mkfs.ext4; do
    command -v "$cmd" &>/dev/null || error "Missing dependency: $cmd"
done

[ "$(id -u)" -ne 0 ] && error "This script must be run as root (use sudo)"

log "=== Debian V86 Image Builder ==="
log "Release: ${DEBIAN_RELEASE} (${DEBIAN_ARCH})"
log "Image size: ${IMG_SIZE}"
log "Output: ${OUTPUT_DIR}/${IMG_NAME}"

# Step 1: Create raw disk image
log "Creating disk image..."
qemu-img create -f raw "${OUTPUT_DIR}/${IMG_NAME}" "${IMG_SIZE}"

# Step 2: Partition the disk (single ext4 partition)
log "Partitioning disk..."
parted -s "${OUTPUT_DIR}/${IMG_NAME}" \
    mklabel msdos \
    mkpart primary ext4 1MiB 100%

# Step 3: Setup loop device and format
log "Setting up loop device..."
LOOP_DEV=$(losetup --find --show --partscan "${OUTPUT_DIR}/${IMG_NAME}")
PART_DEV="${LOOP_DEV}p1"

# Wait for partition device to appear
sleep 1
[ ! -b "$PART_DEV" ] && partprobe "$LOOP_DEV" && sleep 1
[ ! -b "$PART_DEV" ] && error "Partition device $PART_DEV not found"

log "Formatting partition..."
mkfs.ext4 -L "debian-v86" -O ^64bit,^metadata_csum "$PART_DEV"

# Step 4: Mount and debootstrap
log "Mounting partition..."
mkdir -p "${MOUNT_DIR}"
mount "$PART_DEV" "${MOUNT_DIR}"

log "Running debootstrap (this may take a while)..."
debootstrap --arch="${DEBIAN_ARCH}" \
    --variant=minbase \
    --include=linux-image-686,grub-pc,systemd,systemd-sysv,udev,\
dbus,ifupdown,iproute2,iputils-ping,net-tools,nano,less,\
procps,openssh-server,sudo,bash-completion,locales \
    "${DEBIAN_RELEASE}" "${MOUNT_DIR}" "${DEBIAN_MIRROR}"

# Step 5: Configure the system
log "Configuring system..."

# Mount virtual filesystems for chroot
mount --bind /dev "${MOUNT_DIR}/dev"
mount --bind /dev/pts "${MOUNT_DIR}/dev/pts"
mount -t proc proc "${MOUNT_DIR}/proc"
mount -t sysfs sys "${MOUNT_DIR}/sys"

# fstab
cat > "${MOUNT_DIR}/etc/fstab" << 'FSTAB'
# /etc/fstab - Debian V86
/dev/sda1   /       ext4    errors=remount-ro,noatime   0   1
proc        /proc   proc    defaults                    0   0
sysfs       /sys    sysfs   defaults                    0   0
tmpfs       /tmp    tmpfs   defaults,size=64m           0   0
tmpfs       /run    tmpfs   defaults,size=32m           0   0
FSTAB

# Hostname
echo "debian-xbox" > "${MOUNT_DIR}/etc/hostname"
cat > "${MOUNT_DIR}/etc/hosts" << 'HOSTS'
127.0.0.1   localhost
127.0.1.1   debian-xbox
HOSTS

# Network config (static + DHCP fallback)
cat > "${MOUNT_DIR}/etc/network/interfaces" << 'NETWORK'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
NETWORK

# Serial console for V86 (critical for text-mode operation)
cat > "${MOUNT_DIR}/etc/default/grub" << 'GRUB'
GRUB_DEFAULT=0
GRUB_TIMEOUT=3
GRUB_DISTRIBUTOR="Debian V86"
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_CMDLINE_LINUX="console=ttyS0,115200n8 console=tty0 net.ifnames=0 biosdevname=0 nomodeset"
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1"
GRUB
# Kernel modules for V86 compatibility
cat > "${MOUNT_DIR}/etc/initramfs-tools/modules" << 'MODULES'
# V86 emulator compatible modules
atkbd
i8042
virtio_blk
virtio_net
virtio_pci
e1000
ne2k_pci
8390
ext4
MODULES

# System optimizations for emulated environment
cat > "${MOUNT_DIR}/etc/sysctl.d/99-v86-optimize.conf" << 'SYSCTL'
# Optimizations for V86 emulated environment
# Reduce memory pressure
vm.swappiness=10
vm.dirty_ratio=40
vm.dirty_background_ratio=10
# Reduce kernel verbosity after boot
kernel.printk=3 4 1 3
# Disable IPv6 (not supported in V86 network)
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
SYSCTL

# Systemd optimizations - disable heavy services
cat > "${MOUNT_DIR}/etc/systemd/system/serial-getty@ttyS0.service.d/override.conf" << 'OVERRIDE'
# This directory/file is created below
OVERRIDE
mkdir -p "${MOUNT_DIR}/etc/systemd/system/serial-getty@ttyS0.service.d"
cat > "${MOUNT_DIR}/etc/systemd/system/serial-getty@ttyS0.service.d/override.conf" << 'OVERRIDE'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I 115200 linux
OVERRIDE

# Run configuration inside chroot
chroot "${MOUNT_DIR}" /bin/bash << 'CHROOT_SCRIPT'
set -e

# Set root password
echo "root:xbox" | chpasswd

# Create a regular user
useradd -m -s /bin/bash -G sudo xbox
echo "xbox:xbox" | chpasswd

# Enable serial console
systemctl enable serial-getty@ttyS0.service

# Disable unnecessary services for emulated environment
systemctl disable apt-daily.timer 2>/dev/null || true
systemctl disable apt-daily-upgrade.timer 2>/dev/null || true
systemctl disable e2scrub_all.timer 2>/dev/null || true
systemctl disable fstrim.timer 2>/dev/null || true
systemctl mask systemd-timesyncd.service 2>/dev/null || true
systemctl mask ModemManager.service 2>/dev/null || true

# Configure locale
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf

# Configure SSH (allow root login for convenience in emulator)
sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config

# Install GRUB bootloader
grub-install --target=i386-pc --boot-directory=/boot "$LOOP_DEV_INNER" 2>/dev/null || true
update-grub 2>/dev/null || true

# Rebuild initramfs with V86-compatible modules
update-initramfs -u

# Cleanup apt cache
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /tmp/*
CHROOT_SCRIPT

# Install GRUB from outside chroot (more reliable)
log "Installing GRUB bootloader..."
grub-install --target=i386-pc --boot-directory="${MOUNT_DIR}/boot" "$LOOP_DEV" 2>/dev/null || {
    warn "GRUB install from host failed, trying syslinux fallback..."

    # Syslinux fallback (more compatible with V86)
    if command -v syslinux &>/dev/null; then
        mkdir -p "${MOUNT_DIR}/boot/syslinux"

        KERNEL=$(ls "${MOUNT_DIR}/boot/vmlinuz-"* 2>/dev/null | head -1)
        INITRD=$(ls "${MOUNT_DIR}/boot/initrd.img-"* 2>/dev/null | head -1)

        if [ -n "$KERNEL" ] && [ -n "$INITRD" ]; then
            KVER=$(basename "$KERNEL" | sed 's/vmlinuz-//')
            cat > "${MOUNT_DIR}/boot/syslinux/syslinux.cfg" << SYSLINUX_CFG
PROMPT 1
TIMEOUT 30
DEFAULT debian

LABEL debian
    LINUX /boot/vmlinuz-${KVER}
    INITRD /boot/initrd.img-${KVER}
    APPEND root=/dev/sda1 rw console=ttyS0,115200n8 console=tty0 net.ifnames=0 nomodeset quiet
SYSLINUX_CFG
            log "Syslinux config created"
        fi
    fi
}

# Step 6: Generate V86-compatible flat image info
log "Generating image metadata..."
cat > "${OUTPUT_DIR}/debian-v86-info.json" << JSON
{
    "name": "Debian ${DEBIAN_RELEASE} (${DEBIAN_ARCH})",
    "description": "Minimal Debian for V86 emulator on Xbox",
    "image": "${IMG_NAME}",
    "size": "${IMG_SIZE}",
    "arch": "${DEBIAN_ARCH}",
    "kernel_params": "console=ttyS0,115200n8 console=tty0 net.ifnames=0 nomodeset",
    "default_user": "xbox",
    "default_password": "xbox",
    "root_password": "xbox",
    "features": [
        "serial-console",
        "ssh-server",
        "network-dhcp",
        "systemd",
        "bash-completion"
    ]
}
JSON

log "=== Build Complete ==="
log "Image: ${OUTPUT_DIR}/${IMG_NAME}"
log "Size: $(du -h "${OUTPUT_DIR}/${IMG_NAME}" | cut -f1)"
log ""
log "Default credentials:"
log "  root / xbox"
log "  xbox / xbox"
log ""
log "To test with QEMU:"
log "  qemu-system-i386 -m 512 -hda ${OUTPUT_DIR}/${IMG_NAME} -serial stdio -display none"
log ""
log "To convert for V86 split loading:"
log "  ./split-img.sh ${OUTPUT_DIR}/${IMG_NAME}"
