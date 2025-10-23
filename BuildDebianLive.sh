#!/bin/bash

# ═════════════════════════════════════════════════════════════════════════════════════════
# EXECUTION COMMAND AND INITIAL SETUP
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

# RUN THIS SCRIPT WITH THE EXACT COMMAND BELOW
# DO NOT USE RELATIVE PATHS
# sudo -i bash -lc 'exec 3>/tmp/debian-live-build-trace.log; export BASH_XTRACEFD=3; export PS4="+ $(date +%H:%M:%S) ${BASH_SOURCE}:${LINENO}: "; DEBUG=1 /home/matt/Documents/CryptoShred/BuildDebianLive.sh'
# Replace matt with your username and adjust path as needed.

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
    apt update
    if [ "$cmd" = "7z" ]; then
      apt install -y p7zip-full
    elif [ "$cmd" = "unsquashfs" ]; then
      apt install -y squashfs-tools
    else
      apt install -y "$cmd"
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
# INTRODUCTION AND USER CONFIRMATION
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

echo
echo "============================================= Debian Live ISO Builder ============================================="
echo
echo "Debian Live ISO Builder - Create a bootable Debian Live ISO with several packages installed and flash it to USB."
echo "Version 1.2 - 2025-10-22"
echo
echo "This script will:"
echo "  • Download the latest Debian Live ISO"
echo "  • Extract and modify the ISO"
echo "  • Update the system with 'apt update' and 'apt upgrade'"
echo "  • Install several packages"
echo "  • Rebuild the ISO with the modifications"
echo "  • Flash the resulting ISO directly to a specified USB device"
echo
echo "WARNING: This will ERASE ALL DATA on the specified USB device."
echo
echo "IMPORTANT!!! Make sure your target USB device is plugged in before proceeding."
echo
echo "=============================================================================================================="
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
WORKDIR="$REAL_HOME/debian-live-work"
OUTISO="DebianLive-Enhanced.iso"

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
  if lsblk -d -o NAME,TYPE | grep -E "^$USBDEV\\s+disk" > /dev/null; then
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

# === Chroot and install packages ===
echo
echo "[*] Chrooting and performing system updates and package installation..."
echo "[*] This may take several minutes depending on your internet connection..."
cat <<'CHROOT' | chroot edit /bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

echo "[CHROOT] Running apt update..."
apt update

echo "[CHROOT] Running apt upgrade..."
apt -y full-upgrade

echo "[CHROOT] Installing nvme-cli, cryptsetup, disk tools, and networking tools..."
sudo add-apt-repository universe || true
apt -y install nvme-cli cryptsetup \
    util-linux gdisk \
    network-manager network-manager-gnome \
    wireless-tools wpasupplicant \
    curl wget net-tools \
    openssh-client openssh-server \
    ca-certificates gnupg \
    bash-completion tmux screen mc htop lsof ncdu tree pv \
    zip unzip p7zip-full \
    rsync debootstrap lvm2 \
    e2fsprogs ntfs-3g exfatprogs btrfs-progs \
    smartmontools hdparm testdisk gparted \
    nmap netcat-openbsd tcpdump traceroute mtr-tiny iperf3 socat \
    firmware-iwlwifi firmware-realtek firmware-atheros \
    iputils-ping dnsutils \
    lynx

echo "[CHROOT] Installing sedutil-cli for SED drive management..."
# Download sedutil and extract archive
wget "https://github.com/Drive-Trust-Alliance/exec/blob/master/sedutil_LINUX.tgz?raw=true" -O sedutil_LINUX.tgz
tar -xf sedutil_LINUX.tgz

# Move it into the system admin path and make executable
mv sedutil/release_x86_64/sedutil-cli /usr/local/sbin/sedutil-cli
chmod +x /usr/local/sbin/sedutil-cli

# Clean up sedutil files
rm -rf ./sedutil* ./sedutil_LINUX.tgz

echo "[CHROOT] Enabling NetworkManager service..."
systemctl enable NetworkManager

echo "[CHROOT] Configuring NetworkManager for live environment..."
# Ensure NetworkManager starts automatically and manages all interfaces
cat > /etc/NetworkManager/NetworkManager.conf << 'EOF'
[main]
plugins=ifupdown,keyfile
dhcp=dhclient

[ifupdown]
managed=true

[device]
wifi.scan-rand-mac-address=no
EOF

echo "[CHROOT] Setting up network interface naming..."
# Disable predictable network interface names for easier live boot compatibility
ln -sf /dev/null /etc/systemd/network/99-default.link

echo "[CHROOT] Setting up PATH for system tools..."
# Ensure nvme-cli and other system tools are in PATH for all users
echo 'export PATH=$PATH:/usr/sbin:/sbin:/usr/local/sbin' >> /etc/profile
echo 'export PATH=$PATH:/usr/sbin:/sbin:/usr/local/sbin' >> /etc/bash.bashrc
# Also add for live user's bashrc
mkdir -p /home/user
echo 'export PATH=$PATH:/usr/sbin:/sbin:/usr/local/sbin' >> /home/user/.bashrc

echo "[CHROOT] Configuring WiFi stability fixes..."
# Create comprehensive WiFi stability configuration
cat > /etc/modprobe.d/wifi-stability.conf << 'EOF'
# Disable power management for WiFi adapters
options iwlwifi power_save=0 bt_coex_active=0 swcrypto=1
options iwldvm force_cam=1
options mac80211 ieee80211_disable_40mhz_24ghz=1
options cfg80211 ieee80211_regdom=US

# Disable 802.11n for stability on problem networks
options iwlwifi 11n_disable=1
options iwlwifi disable_11ac=1
EOF

# Create NetworkManager configuration for stability
cat > /etc/NetworkManager/conf.d/99-wifi-stability.conf << 'EOF'
[main]
# Disable randomized MAC addresses
wifi.scan-rand-mac-address=no

[device]
# Disable WiFi power saving
wifi.powersave=2

[connection]
# Disable IPv6 to reduce complexity
ipv6.method=ignore

# Force 2.4GHz band for better compatibility
wifi.band=bg
EOF

# Create startup script for WiFi stability
cat > /etc/NetworkManager/dispatcher.d/99-wifi-stability << 'EOF'
#!/bin/bash
# WiFi stability script - runs when network interfaces change

if [ "$1" = "wlan0" ] && [ "$2" = "up" ]; then
    # Disable power management
    iwconfig wlan0 power off 2>/dev/null || true
    
    # Set conservative settings
    iwconfig wlan0 rate 54M 2>/dev/null || true
    
    # Disable 802.11n/ac for stability
    echo "WiFi stability settings applied to $1" >> /var/log/wifi-stability.log
fi
EOF

chmod +x /etc/NetworkManager/dispatcher.d/99-wifi-stability

# Create manual WiFi connection helper script
cat > /usr/local/bin/wifi-connect-manual.sh << 'EOF'
#!/bin/bash
echo "=== Manual WiFi Connection Helper ==="
echo

# Apply WiFi stability settings
iwconfig wlan0 power off 2>/dev/null || true
echo "WiFi power management disabled for stability"
echo

echo "Available WiFi networks:"
nmcli device wifi list
echo

echo "=== Connection Methods ==="
echo "1. Interactive menu: nmtui"
echo "2. Command line: nmcli device wifi connect \"NETWORK_NAME\""
echo "3. For open networks only (no password required)"
echo
echo "=== Captive Portal Help ==="
echo "If connected but no internet:"
echo "1. Find gateway: ip route show default"
echo "2. Access portal: lynx http://GATEWAY_IP"
echo "3. Or try: captive-portal-bypass.sh"
echo
echo "Recommended: Just use 'nmtui' - it's the most reliable method"
EOF

chmod +x /usr/local/bin/wifi-connect-manual.sh

echo "[CHROOT] Cleaning package cache..."
apt clean

echo "[CHROOT] Package installation and network configuration completed successfully!"
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
echo "[*] Modifying GRUB config to skip boot menu..."
GRUB_CFG="iso/boot/grub/grub.cfg"
if [ -f "$GRUB_CFG" ]; then
  sed -i '1i set default=0\nset timeout=0' "$GRUB_CFG"
else
  echo "[!] GRUB config not found at $GRUB_CFG"
  echo "[!] Boot will use default timeout"
fi

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# SQUASHFS REBUILD
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

echo
echo "[*] Rebuilding squashfs..."
mksquashfs edit iso/live/filesystem.squashfs -noappend -e boot

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
XORRISO_ARGS=( -as mkisofs -o "$OUTISO" -r -V "DebianLive-Enhanced" -J -l -iso-level 3 -partition_offset 16 -A "DebianLive-Enhanced" )
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
echo "[*] This may take several minutes depending on USB speed..."
dd if="$OUTISO" of="/dev/$USBDEV" bs=4M status=progress oflag=direct conv=fsync
sync

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# COMPLETION AND VERIFICATION
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

echo
echo "[*] ISO creation and USB flashing completed successfully!"
echo
echo "================================== Build Summary ============================================"
echo "• Debian Live ISO downloaded and extracted"
echo "• ISO: downloaded, modified, rebuilt"
echo "• Key packages: nvme-cli, cryptsetup, sedutil-cli, network tools, lynx, ssh client"
echo "• Network: NetworkManager enabled; WiFi is manual (use 'nmtui')"
echo "• Helpers: /usr/local/bin/wifi-connect-manual.sh installed for manual WiFi connections"
echo "============================================================================================"