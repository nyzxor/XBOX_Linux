# Xbox Linux - Debian Image Build Tools

Tools for building minimal Debian disk images and ISOs optimized for the V86/Halfix JavaScript x86 emulators running on Xbox.

## Quick Start

### Option 1: Build a Live ISO (Recommended)

The ISO approach is simpler and produces a smaller file that boots directly from CD-ROM emulation.

```bash
# Install dependencies
sudo apt install debootstrap xorriso squashfs-tools isolinux syslinux-common mtools

# Build the ISO
sudo ./build-debian-iso.sh ./output

# Copy to emulator directory
cp ./output/debian-xbox.iso ../uwp/XboxLinux/Virtual_Machines5/disc.iso
```

### Option 2: Build a Raw Disk Image

The disk image approach provides persistent storage (changes survive reboots).

```bash
# Install dependencies
sudo apt install qemu-utils debootstrap parted kpartx

# Build the image
sudo ./build-debian-img.sh ./output

# Copy to emulator directory
cp ./output/debian-v86.img ../uwp/XboxLinux/Virtual_Machines5/debian.img
```

Then update `Virtual_Machines5/index.html` to use `hda` instead of `cdrom`.

### Option 3: Manual QEMU Installation

For full control over the installation:

```bash
# Download Debian i386 netinst ISO
wget https://cdimage.debian.org/debian-cd/current/i386/iso-cd/debian-12.*-i386-netinst.iso

# Create disk image
qemu-img create -f raw debian-v86.img 2G

# Install with preseed for automated setup
qemu-system-i386 -m 1024 \
    -hda debian-v86.img \
    -cdrom debian-12-*-i386-netinst.iso \
    -boot d \
    -serial stdio

# After installation, test headless
qemu-system-i386 -m 512 \
    -hda debian-v86.img \
    -serial stdio \
    -display none
```

## Default Credentials

| User  | Password |
|-------|----------|
| root  | xbox     |
| xbox  | xbox     |

## Testing with V86 Node.js

```bash
cd ../shell/v86

# Test with ISO
node nodejs-debian.js /path/to/debian-xbox.iso 512

# Test with disk image
node nodejs-debian.js /path/to/debian-v86.img 512
```

## What Gets Installed

The minimal Debian system includes:
- Linux kernel (i686)
- systemd init system
- Network (DHCP via eth0)
- SSH server
- Serial console (ttyS0 at 115200 baud)
- Basic tools: nano, less, htop, tmux, wget, curl
- sudo configured for the `xbox` user

## Performance Considerations

| Setting | Tiny Core | Debian Minimal | Debian + GUI |
|---------|-----------|----------------|--------------|
| RAM     | 128 MB    | 256-512 MB     | 1-2 GB       |
| Disk    | 8 MB ISO  | 200-500 MB     | 2+ GB        |
| Boot    | ~5 sec    | ~30-60 sec     | ~2-5 min     |
| CPU     | Low       | Medium         | High         |

### Tips for Better Performance

1. **Use `toram` boot option** - Loads entire filesystem to RAM, faster I/O after boot
2. **Disable unnecessary services** - Already done in build scripts
3. **Use serial console** - Avoids VGA rendering overhead
4. **Smaller images boot faster** - The ISO builder uses squashfs compression
5. **Avoid GUI/X11** - Text mode is much faster in emulation

## Architecture

```
V86 (JavaScript/WASM x86 emulator)
  |
  +-- SeaBIOS (firmware)
  |     |
  |     +-- GRUB/Syslinux (bootloader)
  |           |
  |           +-- Linux kernel (i686)
  |                 |
  |                 +-- Debian userspace (systemd)
  |
  +-- WebView2 (Xbox UWP rendering)
        |
        +-- Xbox controller -> Virtual keyboard -> PS/2 scancodes
```

## Files

| File | Description |
|------|-------------|
| `build-debian-iso.sh` | Builds bootable Debian Live ISO |
| `build-debian-img.sh` | Builds raw disk image with GRUB |
| `preseed.cfg` | Automated Debian installer config |
| `README.md` | This file |

## Preseed (Automated Installation)

The `preseed.cfg` file automates Debian installation when using the official netinst ISO with QEMU. It configures partitioning, users, packages, and serial console automatically.
