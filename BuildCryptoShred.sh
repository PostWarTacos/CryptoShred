#!/bin/bash

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# EXECUTION COMMAND AND INITIAL SETUP
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

# RUN THIS SCRIPT WITH THE EXACT COMMAND BELOW
# DO NOT USE RELATIVE PATHS
# sudo -i bash -lc 'exec 3>/tmp/build-trace.log; export BASH_XTRACEFD=3; export PS4="+ $(date +%H:%M:%S) ${BASH_SOURCE}:${LINENO}: "; DEBUG=1 /home/USERNAME/Documents/CryptoShred/BuildCryptoShred.sh'
# Replace USERNAME with your actual username and adjust path as needed.

set -euo pipefail
clear

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# SHELL AND ENVIRONMENT DETECTION
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

# Detect inherited shell xtrace (-x) and disable it here. We'll enable tracing
# later after the logfile is configured if DEBUG=1 or HONOR_SHELL_XTRACE=1.
INHERITED_XTRACE=0
case "$-" in
  *x*) INHERITED_XTRACE=1 ;;
esac
set +x

# If this script was invoked with /bin/sh (or another non-bash shell), re-exec
# using /bin/bash so we can use Bash-specific features like arrays.
if [ -z "${BASH_VERSION:-}" ]; then
  if [ -x /bin/bash ]; then
    exec /bin/bash "$0" "$@"
  else
    echo "[ERROR] /bin/bash not found; this script requires bash." >&2
    exit 1
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# DEBUGGING AND LOGGING SETUP (DISABLED)
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

# Debugging output
# Create a logfile to capture the full run for debugging (timestamped)
# LOGDIR="/var/log/cryptoshred"
# mkdir -p "$LOGDIR"
# LOGFILE="$LOGDIR/build-$(date +%Y%m%d-%H%M%S).log"
# Redirect stdout/stderr to logfile while still allowing console output when interactive
# exec > >(tee -a "$LOGFILE") 2>&1

# echo
# echo "[LOGFILE] $LOGFILE"
# echo "[INFO] Invoked by: $(whoami) (SUDO_USER=${SUDO_USER:-undefined})"
# echo "[INFO] Shell: $SHELL" 
# echo "[INFO] PATH: $PATH"
# echo "[INFO] HOME: $HOME" 
# echo "[INFO] Real home inferred: ${REAL_HOME:-unset}"
# echo "[INFO] Environment dump:" 
# env | sort

# Enable tracing after logfile is ready if requested by DEBUG or by honoring
# an inherited -x (set HONOR_SHELL_XTRACE=1 to enable in that case).
# if [ "${DEBUG:-0}" -ne 0 ] || { [ "${HONOR_SHELL_XTRACE:-0}" -ne 0 ] && [ "$INHERITED_XTRACE" -eq 1 ]; }; then
#   set -x
# fi

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# ROOT PERMISSION CHECK
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

if [ "$EUID" -ne 0 ]; then
  echo
  echo "[!] Please run this script as root (sudo)."
  echo
  exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# TIMING AND CLEANUP SETUP
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

# Record start time
START_TIME=$(date +%s)
START_TS=$(date +"%Y-%m-%d %H:%M:%S")
echo
echo "[TIME] Start: $START_TS"

# Ensure we always record end time and elapsed duration, even on failures
finish() {
  END_TIME=$(date +%s)
  END_TS=$(date +"%Y-%m-%d %H:%M:%S %z")
  ELAPSED=$((END_TIME - START_TIME))
  echo
  echo "[TIME] End: $END_TS"
  echo "[TIME] Elapsed: $((ELAPSED / 60)) min $((ELAPSED % 60)) sec"
}
trap finish EXIT

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# DEPENDENCY VERIFICATION
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

# === Verify required tools are installed on local host ===
echo
echo "[*] Checking for required tools..."
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

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# UPDATE CHECKING (DISABLED)
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

# === Hash-based update check (DISABLED) ===
# Uncomment the following section to enable hash-based auto-updating
# REMOTE_URL="https://raw.githubusercontent.com/PostWarTacos/CryptoShred/refs/heads/main/BuildCryptoShred.sh"

# # Calculate hash of current script
# LOCAL_HASH=$(sha256sum "$0" | cut -d' ' -f1)

# # Download remote script to temp file and calculate its hash
# echo
# echo "[*] Checking for BuildCryptoShred.sh updates using hash comparison..."
# REMOTE_SCRIPT="$(mktemp)"
# if curl -s "$REMOTE_URL" -o "$REMOTE_SCRIPT"; then
#   REMOTE_HASH=$(sha256sum "$REMOTE_SCRIPT" | cut -d' ' -f1)
#   
#   # Compare hashes
#   if [ "$LOCAL_HASH" != "$REMOTE_HASH" ]; then
#     echo
#     echo "[!] Local script hash differs from remote version."
#     echo "    Local:  $LOCAL_HASH"
#     echo "    Remote: $REMOTE_HASH"
#     echo "    Updating local script with the latest version..."
#     cp "$REMOTE_SCRIPT" "$0"
#     echo
#     echo "[+] Script updated. Please re-run BuildCryptoShred.sh."
#     rm "$REMOTE_SCRIPT"
#     exit 0
#   else
#     echo "[+] BuildCryptoShred.sh is up to date (hash: ${LOCAL_HASH:0:16}...)"
#   fi
#   rm "$REMOTE_SCRIPT"
# else
#   echo "[!] Warning: Could not download remote script for comparison. Continuing with local version."
# fi

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# INTRODUCTION AND USER CONFIRMATION
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

echo
echo "================================================= CryptoShred ISO Builder ================================================="
echo
echo "CryptoShred ISO Builder - Create a bootable Debian-based ISO with CryptoShred pre-installed"
echo "Version 1.6 - 2025-10-02"
echo
echo "This script will create a bootable Debian-based ISO with CryptoShred.sh pre-installed and configured to run on first boot."
echo "The resulting ISO will be written directly to the specified USB device."
echo "Make sure to change the USB device and script are in place before proceeding."
echo "WARNING: This will ERASE ALL DATA on the specified USB device."
echo
echo "IMPORTANT!!! Make sure your target USB device (device to have Debian/CryptoShred ISO installed) is plugged in."
echo
echo "==========================================================================================================================="
echo
read -p "Press Enter to continue..."

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# CONFIGURATION AND SETUP
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

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

while true; do
# List local drives (excluding loop, CD-ROM, and removable devices)
  echo
  echo "Select the target USB device to write the ISO to."
  echo "Make sure to choose the correct device as all data on it will be erased!"
  echo
  echo "Available local drives:"
  lsblk -d -o NAME,SIZE,MODEL,TYPE,MOUNTPOINT | grep -E 'disk' | grep -vi $BOOTDEV
  echo
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

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# WORKSPACE PREPARATION
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

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

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# CRYPTOSHRED SCRIPT PREPARATION
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

# === Simple local copy approach ===
# Handle path resolution when script is run with sudo -i (which changes to root's environment)
# Try multiple methods to find the script directory
SCRIPT_DIR=""

# Method 1: Check if $0 contains full path
if [[ "$0" == /* ]]; then
  SCRIPT_DIR="$(dirname "$0")"
# Method 2: Check BASH_SOURCE array
elif [ -n "${BASH_SOURCE[0]:-}" ] && [[ "${BASH_SOURCE[0]}" == /* ]]; then
  SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
# Method 3: Extract from command line (when run with the specific sudo command)
elif command -v pgrep >/dev/null 2>&1; then
  # Try to find the full path from the process command line
  CMDLINE=$(cat /proc/$$/cmdline 2>/dev/null | tr '\0' ' ' | grep -o '/[^ ]*BuildCryptoShred\.sh' | head -1)
  if [ -n "$CMDLINE" ]; then
    SCRIPT_DIR="$(dirname "$CMDLINE")"
  fi
fi

# Fallback: Use dynamic path based on the user who ran sudo
if [ -z "$SCRIPT_DIR" ] || [ ! -d "$SCRIPT_DIR" ]; then
  if [ -n "${SUDO_USER:-}" ]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    SCRIPT_DIR="$USER_HOME/Documents/CryptoShred"
  else
    # Ultimate fallback if SUDO_USER is not set
    SCRIPT_DIR="/home/$(logname 2>/dev/null || echo "user")/Documents/CryptoShred"
  fi
  echo "[WARN] Using fallback script directory: $SCRIPT_DIR"
fi

LOCAL_CRYPTOSHRED="$SCRIPT_DIR/CryptoShred.sh"

echo
echo "[*] Using local CryptoShred.sh from directory..."
echo "[DEBUG] Script directory: $SCRIPT_DIR"
echo "[DEBUG] Looking for CryptoShred.sh at: $LOCAL_CRYPTOSHRED"

# Check if local file exists
if [ ! -f "$LOCAL_CRYPTOSHRED" ]; then
  echo "[!] Error: Local CryptoShred.sh not found at $LOCAL_CRYPTOSHRED"
  echo "[!] Please ensure CryptoShred.sh is in the same directory as BuildCryptoShred.sh"
  echo "[DEBUG] Current working directory: $(pwd)"
  echo "[DEBUG] \$0 = $0"
  echo "[DEBUG] BASH_SOURCE[0] = ${BASH_SOURCE[0]:-unset}"
  echo "[DEBUG] Process cmdline: $(cat /proc/$$/cmdline 2>/dev/null | tr '\0' ' ')"
  echo "[DEBUG] Files in script directory:"
  ls -la "$SCRIPT_DIR/" 2>/dev/null || echo "Cannot list script directory"
  exit 1
fi

echo "[+] Found local CryptoShred.sh"
mkdir -p "$(dirname "$CRYPTOSHRED_SCRIPT")"
cp "$LOCAL_CRYPTOSHRED" "$CRYPTOSHRED_SCRIPT"

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# DEBIAN ISO DOWNLOAD
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

echo
echo "[*] Fetching latest Debian ISO link..."
ISO_URL=$(curl -s "https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid/" | 
  grep -oP 'href="debian-live-[0-9.]+-amd64-standard\.iso"' | head -n1 | cut -d'"' -f2)
echo "[*] Downloading $ISO_URL..."
wget -q --show-progress "https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid/$ISO_URL" -O debian.iso

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# ISO EXTRACTION AND MODIFICATION
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

echo
echo "[*] Extracting ISO..."
7z x debian.iso -oiso >/dev/null

# Extract squashfs
echo
echo "[*] Extracting squashfs..."
unsquashfs iso/live/filesystem.squashfs
mv squashfs-root/* edit
rm -rf squashfs-root

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# CRYPTOSHRED INTEGRATION
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

echo "[*] Copying CryptoShred.sh to usr/bin..."
if [ ! -f "$CRYPTOSHRED_SCRIPT" ]; then
  echo
  echo "[!] $CRYPTOSHRED_SCRIPT not found. Aborting."
  exit 1
fi
mkdir -p edit/usr/bin
cp -- "$CRYPTOSHRED_SCRIPT" "edit/usr/bin/CryptoShred.sh"
chmod 755 "edit/usr/bin/CryptoShred.sh"

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# SYSTEMD SERVICE CREATION
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

echo
echo "[*] Creating CryptoShred service..."
cat > edit/etc/systemd/system/cryptoshred.service <<'EOF'
[Unit]
Description=CryptoShred autorun (first-boot)
After=systemd-udev-settle.service local-fs.target getty@tty1.service
Wants=systemd-udev-settle.service
DefaultDependencies=no

[Service]
Type=simple
Restart=always
RestartSec=5
# Wait for system to be fully ready
ExecStartPre=/bin/sleep 10
# Stop getty on tty1 to free it up  
ExecStartPre=-/bin/systemctl stop getty@tty1.service
# Run script in a loop - restart after each completion to allow multiple disk shredding
ExecStart=/bin/bash -c 'export SYSTEMD_EXEC_PID=$$; export NO_CLEAN_ENV=1; export TERM=linux; while true; do echo; echo "[*] CryptoShred ready for next disk..."; echo; if ! /usr/bin/CryptoShred.sh </dev/tty1 >/dev/tty1 2>&1; then echo "=== CRYPTOSHRED FAILED - Check USB and reboot ===" > /dev/tty1; echo "System will restart in 30 seconds. CryptoShred will reinitialize shortly after..." > /dev/tty1; sleep 30; break; fi; echo; echo "[+] Drive shredding completed. Insert another drive to continue or reboot to exit."; echo; sleep 10; done'
# If service fails completely, still try to restart getty
ExecStopPost=-/bin/systemctl start getty@tty1.service
TimeoutStartSec=25m
TimeoutStopSec=30s

[Install]
WantedBy=sysinit.target
EOF

# Enable service under sysinit.target (use relative symlink for portability inside image)
mkdir -p edit/etc/systemd/system/sysinit.target.wants
ln -sf ../cryptoshred.service edit/etc/systemd/system/sysinit.target.wants/cryptoshred.service
cd "$WORKDIR"

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# CHROOT ENVIRONMENT SETUP
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

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
apt-get -y install wget ca-certificates cryptsetup

echo "[*] Installing sedutil-cli for SED drive management..."
# Download sedutil and extract archive
wget "https://github.com/Drive-Trust-Alliance/exec/blob/master/sedutil_LINUX.tgz?raw=true" -O sedutil_LINUX.tgz
tar -xf sedutil_LINUX.tgz

# Move it into the system admin path and make executable
mv sedutil/release_x86_64/sedutil-cli /usr/local/sbin/sedutil-cli
chmod +x /usr/local/sbin/sedutil-cli

# Clean up sedutil files
rm -rf ./sedutil* ./sedutil_LINUX.tgz

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

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# GRUB BOOTLOADER CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

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

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# SQUASHFS REBUILD
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

echo
echo "[*] Rebuilding squashfs..."
mksquashfs edit iso/live/filesystem.squashfs -noappend -e boot

# Verify the cryptoshred service and its enablement symlink exist in the edit tree
if [ ! -f "edit/etc/systemd/system/cryptoshred.service" ] || [ ! -L "edit/etc/systemd/system/sysinit.target.wants/cryptoshred.service" ]; then
  echo
  echo "[ERROR] cryptoshred.service or its enablement symlink is missing from the edit tree after squashfs rebuild."
  echo "[ERROR] Please check edit/etc/systemd/system and edit/etc/systemd/system/sysinit.target.wants"
  exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# ISO BUILDING
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

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

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# USB WRITING
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

echo
echo "[*] Writing ISO to USB ($USBDEV)..."
dd if="$OUTISO" of="/dev/$USBDEV" bs=4M status=progress oflag=direct conv=fsync
sync

echo
echo "[+] Done. USB is ready!"