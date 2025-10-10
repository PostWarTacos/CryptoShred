

# updates needed
# install/update curl
# move verify apps up



#!/bin/bash
set -euo pipefail
clear

# Optional debugging/tracing. Set DEBUG=1 in environment to enable shell tracing.
if [ "${DEBUG:-0}" -ne 0 ] 2>/dev/null; then
  set -x
fi

# Create a logfile to capture the full run for debugging (timestamped)
LOGDIR="/var/log/cryptoshred"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/build-$(date +%Y%m%d-%H%M%S).log"
# Redirect stdout/stderr to logfile while still allowing console output when interactive
exec > >(tee -a "$LOGFILE") 2>&1

echo
echo "[LOGFILE] $LOGFILE"
echo "[INFO] Invoked by: $(whoami) (SUDO_USER=${SUDO_USER:-undefined})"
echo "[INFO] Shell: $SHELL" 
echo "[INFO] PATH: $PATH"
echo "[INFO] HOME: $HOME" 
echo "[INFO] Real home inferred: ${REAL_HOME:-unset}"
echo "[INFO] Environment dump:" 
env | sort

if [ "$EUID" -ne 0 ]; then
  echo
  echo "[!] Please run this script as root (sudo)."
  echo
  exit 1
fi

# Record start time
START_TIME=$(date +%s)

# === Version check ===
# Dynamically extract version from this script
SCRIPT_VERSION=$(grep -m1 -oP 'Version\s+\K[0-9\. -]+' "$0")
REMOTE_URL="https://raw.githubusercontent.com/PostWarTacos/CryptoShred/refs/heads/main/BuildCryptoShred.sh"

# Download remote script to temp file and extract version
echo
echo "[*] Checking for latest BuildCryptoShred.sh version online..."
REMOTE_SCRIPT="$(mktemp)"
curl -s "$REMOTE_URL" -o "$REMOTE_SCRIPT"
REMOTE_VERSION=$(grep -m1 -oP 'Version\s+\K[0-9\. -]+' "$REMOTE_SCRIPT")

# Compare versions
if [ "$SCRIPT_VERSION" != "$REMOTE_VERSION" ]; then
  echo
  echo "[!] Local script version ($SCRIPT_VERSION) does not match latest online version ($REMOTE_VERSION)."
  echo "    Updating local script with the latest version..."
  cp "$REMOTE_SCRIPT" "$0"
  echo
  echo "[+] Script updated. Please re-run BuildCryptoShred.sh."
  rm "$REMOTE_SCRIPT"
  exit 0
fi
rm "$REMOTE_SCRIPT"

# === Main script ===
echo
echo "================================================= CryptoShred ISO Builder ================================================="
echo
echo "CryptoShred ISO Builder - Create a bootable Debian-based ISO with CryptoShred pre-installed"
echo "Version 1.4.1 - 2025-10-02"
echo
echo "This script will create a bootable Debian-based ISO with CryptoShred.sh pre-installed and configured to run on first boot."
echo "The resulting ISO will be written directly to the specified USB device."
echo "Make sure to change the USB device and script are in place before proceeding."
echo "WARNING: This will ERASE ALL DATA on the specified USB device."

# === User verification step ===
echo
echo "IMPORTANT!!! Make sure your target USB device (device to have Debian/CryptoShred ISO installed) is plugged in."
echo
echo "==========================================================================================================================="
echo
read -p "Press Enter to continue..."

# === Config ===
# Get the real user's home directory (not root's when using sudo)
if [ -n "${SUDO_USER:-}" ]; then
  REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
  REAL_HOME="$HOME"
fi
WORKDIR="$REAL_HOME/live-iso-work"
OUTISO="CryptoShred.iso"
#USBDEV="/dev/sda"
CRYPTOSHRED_SCRIPT="$WORKDIR/CryptoShred.sh"

# Identify the boot device to prevent accidental selection
BOOTDEV=$(findmnt -no SOURCE / | xargs -I{} lsblk -no PKNAME {})

# List local drives (excluding loop, CD-ROM, and removable devices)
echo
echo "Select the target USB device to write the ISO to."
echo "Make sure to choose the correct device as all data on it will be erased!"
echo
echo "Available local drives:"
lsblk -d -o NAME,SIZE,MODEL,TYPE,MOUNTPOINT | grep -E 'disk' | grep -vi $BOOTDEV
echo
while true; do
  # Prompt for device to write ISO to
  read -p "Enter the device to write ISO to (e.g., sdb, nvme0n1): " USBDEV
  # Check if entered device is in the lsblk output and is a disk
  if lsblk -d -o NAME,TYPE | grep -E "^$USBDEV\s+disk" > /dev/null; then
    # Prevent wiping the boot device
    if [[ "$USBDEV" == "$BOOTDEV" ]]; then
      echo
      echo "ERROR: /dev/$USBDEV appears to be the boot device. Please choose another device."
      read -p "Press Enter to continue..."
      clear
      continue
    fi
    break
  fi
  echo
  echo "Device /dev/$USBDEV is not a valid local disk from the list above. Please try again."
  read -p "Press Enter to continue..."
  clear
done

# === Prep Working Directory ===
echo
echo "[*] Cleaning old build dirs..."
if [ -d "$WORKDIR" ]; then
  rm -rf "$WORKDIR"
fi
mkdir -p "$WORKDIR/edit"
mkdir -p "$WORKDIR/iso"
# Only attempt to chown if SUDO_USER is set and maps to a valid user
if [ -n "${SUDO_USER:-}" ] && getent passwd "$SUDO_USER" >/dev/null 2>&1; then
  chown "$SUDO_USER":"$SUDO_USER" "$WORKDIR"
fi
chmod 700 "$WORKDIR"
cd "$WORKDIR"

# === Download latest CryptoShred.sh ===
REMOTE_CRYPTOSHRED_URL="https://raw.githubusercontent.com/PostWarTacos/CryptoShred/refs/heads/main/CryptoShred.sh"
echo "[*] Downloading latest CryptoShred.sh..."
curl -s "$REMOTE_CRYPTOSHRED_URL" -o "$CRYPTOSHRED_SCRIPT"

echo
echo "[*] Downloading latest CryptoShred.sh..."
mkdir -p "$(dirname "$CRYPTOSHRED_SCRIPT")"
if ! curl -s "$REMOTE_CRYPTOSHRED_URL" -o "$CRYPTOSHRED_SCRIPT"; then
  echo
  echo "[!] Failed to download CryptoShred.sh from $REMOTE_CRYPTOSHRED_URL"
  exit 1
fi


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
mv squashfs-root/* edit
rm -rf squashfs-root

# === 3. Copy CryptoShred.sh directly to /usr/bin in the chroot ===
echo "[*] Copying CryptoShred.sh to usr/bin..."
echo
echo "[*] Copying CryptoShred.sh to usr/bin..."
if [ ! -f "$CRYPTOSHRED_SCRIPT" ]; then
  echo
  echo "[!] $CRYPTOSHRED_SCRIPT not found. Aborting."
  exit 1
fi
mkdir -p edit/usr/bin
cp -- "$CRYPTOSHRED_SCRIPT" "edit/usr/bin/CryptoShred.sh"
chmod 755 "edit/usr/bin/CryptoShred.sh"

# === 4. Create and enable service ===
echo
echo "[*] Creating CryptoShred service..."
cat > edit/etc/systemd/system/cryptoshred.service <<'EOF'
[Unit]
Description=CryptoShred autorun
DefaultDependencies=no
After=systemd-udevd.service systemd-udev-settle.service local-fs-pre.target
Before=local-fs.target
Wants=systemd-udev-settle.service

[Service]
Type=simple
ExecStartPre=/bin/sleep 10
ExecStart=/bin/bash -i /usr/bin/CryptoShred.sh < /dev/tty1 > /dev/tty1 2>&1
StandardOutput=journal+console
StandardError=journal+console
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=sysinit.target
EOF

# Enable service
cd edit/etc/systemd/system/sysinit.target.wants
ln -sf /etc/systemd/system/cryptoshred.service cryptoshred.service
cd "$WORKDIR"

# === 5. Chroot actions ===
echo
echo "[*] Mounting for chroot..."
mount --bind /dev edit/dev
mount --bind /run edit/run
mount -t proc /proc edit/proc
mount -t sysfs /sys edit/sys
mount -t tmpfs tmpfs edit/tmp
mount -t devpts /dev/pts edit/dev/pts

# Setup networking for chroot
echo
echo "[*] Setting up networking for chroot..."
cp /etc/resolv.conf edit/etc/resolv.conf
cat > edit/etc/apt/sources.list <<'EOF'
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
EOF


# === Chroot and install cryptsetup ===
echo
echo "[*] Chrooting and installing cryptsetup..."
cat <<'CHROOT' | chroot edit /bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get -y full-upgrade
apt-get -y install cryptsetup
apt-get clean

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
umount -lf edit/tmp || true


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
# Locate isohdpfx.bin used by isohybrid. Different distros/packages install it in
# different locations. Try a set of common candidates and only pass the option
# to xorriso if we find it on the host filesystem.
ISOHYBRID_CANDIDATES=(
  /usr/lib/ISOLINUX/isohdpfx.bin
  /usr/lib/isolinux/isohdpfx.bin
  /usr/lib/syslinux/isohdpfx.bin
  /usr/lib/syslinux/modules/bios/isohdpfx.bin
  /usr/lib/syslinux/modules/efi/isohdpfx.bin
)
ISOHYBRID_MBR_OPT=""
for cand in "${ISOHYBRID_CANDIDATES[@]}"; do
  if [ -f "$cand" ]; then
    ISOHYBRID_MBR_OPT=( -isohybrid-mbr "$cand" )
    echo "[INFO] Using isohybrid MBR from: $cand"
    break
  fi
done
if [ -z "${ISOHYBRID_MBR_OPT[*]:-}" ]; then
  echo "[WARN] isohdpfx.bin not found in known locations; proceeding without -isohybrid-mbr."
  echo "[WARN] This may affect BIOS bootability on some systems."
fi

# Build the ISO. Use the computed ISOHYBRID_MBR_OPT (may be empty).
ISO_ROOT="$WORKDIR/iso"
if [ ! -d "$ISO_ROOT" ]; then
  echo "[ERROR] ISO root directory not found at $ISO_ROOT"
  exit 1
fi

# Check isolinux files; if missing, skip BIOS isolinux options (ISO will still have EFI boot if present)
ISOLINUX_OPTIONS=()
if [ -f "$ISO_ROOT/isolinux/isolinux.bin" ] && [ -f "$ISO_ROOT/isolinux/boot.cat" ]; then
  ISOLINUX_OPTIONS=( -c isolinux/boot.cat -b isolinux/isolinux.bin -no-emul-boot -boot-load-size 4 -boot-info-table )
else
  echo "[WARN] isolinux/isolinux.bin or isolinux/boot.cat not found in $ISO_ROOT; skipping isolinux BIOS options."
fi

# Check EFI image
EFI_OPT=()
if [ -f "$ISO_ROOT/boot/grub/efi.img" ]; then
  EFI_OPT=( -eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot -isohybrid-gpt-basdat )
else
  echo "[WARN] EFI image boot/grub/efi.img not found in $ISO_ROOT; skipping EFI options."
fi

# Build argument array safely and run xorriso
XORRISO_ARGS=( -as mkisofs -o "$OUTISO" -r -V "CryptoShred" -J -l -iso-level 3 -partition_offset 16 -A "CryptoShred" )
if [ -n "${ISOHYBRID_MBR_OPT[*]:-}" ]; then
  XORRISO_ARGS+=( "${ISOHYBRID_MBR_OPT[@]}" )
fi
XORRISO_ARGS+=( "${ISOLINUX_OPTIONS[@]}" )
XORRISO_ARGS+=( "${EFI_OPT[@]}" )
XORRISO_ARGS+=( "$ISO_ROOT" )

echo "[INFO] Running: xorriso ${XORRISO_ARGS[*]}"
xorriso "${XORRISO_ARGS[@]}"

# === 9. Write ISO to USB ===
echo
echo "[*] Writing ISO to USB ($USBDEV)..."
dd if="$OUTISO" of="/dev/$USBDEV" bs=4M status=progress oflag=direct conv=fsync
sync

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
echo
echo "[+] Done. USB is ready!"
echo "[*] Total time elapsed: $((ELAPSED / 60)) min $((ELAPSED % 60)) sec"