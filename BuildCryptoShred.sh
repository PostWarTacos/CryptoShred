#!/bin/bash
set -euo pipefail
clear

if [ "$EUID" -ne 0 ]; then
  echo "[!] Please run this script as root (sudo)."
  exit 1
fi

echo "========================================= CryptoShred ISO Builder =========================================================="
echo
echo "CryptoShred ISO Builder - Create a bootable Debian-based ISO with CryptoShred pre-installed"
echo "Version 1.2 - 2025-10-01"
echo
echo "This script will create a bootable Debian-based ISO with CryptoShred.sh pre-installed and configured to run on first boot."
echo "The resulting ISO will be written directly to the specified USB device."
echo "Make sure to change the USB device and script are in place before proceeding."
echo "WARNING: This will ERASE ALL DATA on the specified USB device."
echo
echo "============================================================================================================================"
echo

# === Config ===
# Get the real user's home directory (not root's when using sudo)
if [ -n "${SUDO_USER:-}" ]; then
  REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
  REAL_HOME="$HOME"
fi
WORKDIR="$REAL_HOME/live-iso-work"
OUTISO="CryptoShred.iso"
USBDEV="/dev/sda"   # CHANGE THIS to your USB device
CRYPTOSHRED_SCRIPT="$WORKDIR/CryptoShred.sh"

# === Preparation ===
echo
echo "[*] Cleaning old build dirs..."
if [ -d "$WORKDIR" ]; then
  rm -rf "$WORKDIR"
fi
mkdir -p "$WORKDIR/edit"
mkdir -p "$WORKDIR/iso"
cd "$WORKDIR"
echo

# === User verification step ===
while true; do
  echo
  echo "============================================================================================================================"
  echo
  echo "Please ensure you have downloaded the latest version of CryptoShred.sh and placed it in $REAL_HOME/live-iso-work/CryptoShred.sh"
  echo "Also, make sure your target USB device (device to have Debian/CryptoShred ISO installed) is plugged in."
  echo
  echo "============================================================================================================================"
  echo
  if [ ! -f "$CRYPTOSHRED_SCRIPT" ]; then
    echo "[!] CryptoShred.sh not found at $CRYPTOSHRED_SCRIPT."
    echo "    Please download and place it there before continuing."
    read -p "Press Enter to retry..."
    clear
    continue
  fi
  read -p "Press Enter to continue..."
  break
done

# === Verify required tools are installed on local host ===
for cmd in cryptsetup 7z unsquashfs xorriso wget curl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo
    echo "[!] $cmd is not installed. Attempting to install..."
    apt-get update
    if [ "$cmd" = "7z" ]; then
      apt-get install -y p7zip-full
    elif [ "$cmd" = "unsquashfs" ]; then
      apt-get install -y squashfs-tools
    else
      apt-get install -y "$cmd"
    fi
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo
      echo "[!] Failed to install $cmd. Please install it manually."
      read -p "Press Enter to continue..."
      exit 1
    fi
  fi
done

# === 1. Download latest Debian LTS netinst/live ISO ===
echo
echo "[*] Fetching latest Debian ISO link..."
ISO_URL=$(curl -s https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid/ | \
  grep -oP 'href="debian-live-[\d\.]+-amd64-standard\.iso"' | \
  head -1 | \
  cut -d'"' -f2)
echo "[*] Downloading $ISO_URL..."
wget -q --show-progress \
  "https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid/$ISO_URL" \
  -O debian.iso

# === 2. Extract ISO contents ===
echo
echo "[*] Extracting ISO..."
7z x debian.iso -oiso >/dev/null

# Extract squashfs
echo
echo "[*] Extracting squashfs..."
unsquashfs iso/live/filesystem.squashfs
mv squashfs-root edit

# === 3. Copy CryptoShred.sh directly to /usr/bin in the chroot ===
echo
echo "[*] Copying CryptoShred.sh to usr/bin..."
cp $CRYPTOSHRED_SCRIPT edit/usr/bin/CryptoShred.sh
chmod 755 edit/usr/bin/CryptoShred.sh

# === 4. Create and enable service ===
cat > edit/etc/systemd/system/cryptoshred.service <<'EOF'
[Unit]
Description=CryptoShred autorun
DefaultDependencies=no
After=systemd-udevd.service systemd-udev-settle.service local-fs-pre.target
Before=local-fs.target
Wants=systemd-udev-settle.service

[Service]
Type=simple
ExecStart=/usr/bin/CryptoShred.sh
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=sysinit.target
EOF

# Enable service
cd edit/etc/systemd/system/sysinit.target.wants
ln -sf ../cryptoshred.service cryptoshred.service
cd "$WORKDIR"

# === 5. Mount drives for chroot ===
echo
echo "[*] Mounting for chroot..."
mount --bind /dev edit/dev
mount --bind /run edit/run
mount -t proc /proc edit/proc
mount -t sysfs /sys edit/sys
mount -t devpts /dev/pts edit/dev/pts

#cp /etc/resolv.conf edit/etc/resolv.conf

cat <<'CHROOT' | chroot edit /bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

cat >/etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
EOF

apt-get update
apt-get -y upgrade
apt-get -y install cryptsetup

exit
CHROOT

# Cleanup mounts
echo
echo "[*] Cleaning up mounts..."
umount -lf edit/dev/pts || true
umount -lf edit/dev || true
umount -lf edit/run || true
umount -lf edit/proc || true
umount -lf edit/sys || true


# === 6. Modify GRUB config to force first option ===
echo
echo "[*] Modifying GRUB config..."
GRUB_CFG="iso/boot/grub/grub.cfg"
if [ -f "$GRUB_CFG" ]; then
  sed -i '1i set default=0\nset timeout=0' "$GRUB_CFG"
else
  echo "[!] GRUB config not found at $GRUB_CFG"
  read -p "Press Enter to continue..."
  exit 1
fi

# === 7. Rebuild squashfs ===
echo
echo "[*] Rebuilding squashfs..."
mksquashfs edit iso/live/filesystem.squashfs -noappend -e boot

# === 8. Rebuild ISO ===
echo
echo "[*] Building ISO..."
xorriso -as mkisofs -o "$OUTISO" \
  -r -V "CryptoShred" \
  -J -l -cache-inodes -iso-level 3 \
  -partition_offset 16 -A "CryptoShred" \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
  -c isolinux/boot.cat -b isolinux/isolinux.bin \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -e boot/grub/efi.img -no-emul-boot -isohybrid-gpt-basdat \
  iso

# === 9. Write ISO to USB ===
echo
echo "[*] Writing ISO to USB ($USBDEV)..."
dd if="$OUTISO" of="$USBDEV" bs=4M status=progress oflag=direct conv=fsync
sync

echo
echo "[+] Done. USB is ready!"
