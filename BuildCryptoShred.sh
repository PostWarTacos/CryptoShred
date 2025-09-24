#!/bin/bash
set -euo pipefail
clear

# === Config ===
WORKDIR="$HOME/live-iso-work"
OUTISO="CryptoShred.iso"
USBDEV="/dev/sdX"   # CHANGE THIS to your USB device
CRYPTOSHRED_SCRIPT="$WORKDIR/CryptoShred.sh"

# === Preparation ===
echo
echo "[*] Cleaning old build dirs..."
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

# === Verify required tools are installed on local host ===
for cmd in cryptsetup 7z unsquashfs xorriso wget; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo
    echo "[!] $cmd is not installed. Attempting to install..."
    sudo apt-get update
    sudo apt-get install -y "$cmd"
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo
      echo "[!] Failed to install $cmd. Please install it manually."
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
mkdir squashfs-root edit
unsquashfs iso/live/filesystem.squashfs
mv squashfs-root edit

# === 3. Copy CryptoShred.sh directly to /usr/bin in the chroot ===
echo
echo "[*] Copying CryptoShred.sh to usr/bin..."
cp $CRYPTOSHRED_SCRIPT edit/usr/bin/CryptoShred.sh
chmod 755 edit/usr/bin/CryptoShred.sh

# === 4. Chroot to update packages ===
echo
echo "[*] Mounting for chroot..."
mount --bind /dev edit/dev
mount --bind /run edit/run
mount -t proc /proc edit/proc
mount -t sysfs /sys edit/sys
mount -t devpts /dev/pts edit/dev/pts

cat <<'CHROOT' | chroot edit /bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get -y upgrade
apt-get -y install cryptsetup

# Create systemd service
cat >/etc/systemd/system/cryptoshred.service <<'EOF'
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
ln -sf /etc/systemd/system/cryptoshred.service \
      /etc/systemd/system/sysinit.target.wants/cryptoshred.service

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


# === 5. Modify GRUB config to force first option ===
echo
echo "[*] Modifying GRUB config..."
GRUB_CFG="iso/boot/grub/grub.cfg"
if [ -f "$GRUB_CFG" ]; then
  sed -i '1i set default=0\nset timeout=0' "$GRUB_CFG"
else
  echo "[!] GRUB config not found at $GRUB_CFG"
  exit 1
fi

# === 6. Rebuild squashfs ===
echo
echo "[*] Rebuilding squashfs..."
mksquashfs edit iso/live/filesystem.squashfs -noappend -e boot

# === 7. Rebuild ISO ===
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

# === 8. Write ISO to USB ===
echo
echo "[*] Writing ISO to USB ($USBDEV)..."
dd if="$OUTISO" of="$USBDEV" bs=4M status=progress oflag=direct conv=fsync
sync

echo
echo "[+] Done. USB is ready!"
