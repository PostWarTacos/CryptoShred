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

# Color definitions for installation messages
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

# Initialize package tracking arrays
INSTALLED_PACKAGES=()
FAILED_PACKAGES=()

echo "[CHROOT] Running apt update..."
apt update

echo "[CHROOT] Running apt upgrade..."
apt -y full-upgrade

echo "[CHROOT] Installing nvme-cli, cryptsetup, disk tools, and networking tools..."
# Install core packages individually to track each one
CORE_PACKAGES=(nvme-cli cryptsetup util-linux gdisk network-manager network-manager-gnome wireless-tools wpasupplicant curl wget net-tools ca-certificates gnupg firmware-iwlwifi firmware-realtek firmware-atheros iputils-ping lynx)
echo -e "${YELLOW}Installing core packages individually: ${CORE_PACKAGES[*]}${NC}"
CORE_SUCCESS=0
CORE_FAILED=0
for pkg in "${CORE_PACKAGES[@]}"; do
    echo -e "${YELLOW}Installing $pkg...${NC}"
    if apt -y install "$pkg"; then
        echo -e "${GREEN}✓ $pkg: SUCCESS${NC}"
        CORE_SUCCESS=$((CORE_SUCCESS + 1))
        INSTALLED_PACKAGES+=("$pkg")
    else
        echo -e "${RED}✗ $pkg: FAILED${NC}"
        CORE_FAILED=$((CORE_FAILED + 1))
        FAILED_PACKAGES+=("$pkg")
    fi
done
echo "Core packages: $CORE_SUCCESS/${#CORE_PACKAGES[@]} succeeded"
if [ $CORE_FAILED -gt 0 ]; then
    echo ">>> PAUSING: $CORE_FAILED core packages failed <<<"
    echo "Failed packages: ${FAILED_PACKAGES[*]}"
    echo "WARNING: $CORE_FAILED core packages failed."
    echo "Sleeping for 10 seconds to allow screenshot..."
    sleep 10
    echo ">>> CONTINUING after pause <<<"
fi

# Install SSH client only
echo "[CHROOT] Installing SSH client..."
echo -e "${YELLOW}Cleaning package system before SSH installation...${NC}"
apt-get clean
apt-get autoclean
apt-get autoremove -y
dpkg --configure -a
apt-get install -f -y

echo -e "${YELLOW}Installing SSH client: openssh-client${NC}"
SSH_SUCCESS=0
SSH_FAILED=0

echo -e "${YELLOW}Installing openssh-client...${NC}"
if apt -y install openssh-client; then
    echo -e "${GREEN}✓ openssh-client: SUCCESS${NC}"
    SSH_SUCCESS=1
    INSTALLED_PACKAGES+=(openssh-client)
else
    echo -e "${RED}✗ openssh-client: FAILED${NC}"
    SSH_FAILED=1
    FAILED_PACKAGES+=(openssh-client)
fi
echo "SSH client: $SSH_SUCCESS/1 succeeded"
if [ $SSH_FAILED -gt 0 ]; then
    echo ">>> PAUSING: SSH client failed <<<"
    echo "WARNING: SSH client installation failed."
    echo "Sleeping for 10 seconds to allow screenshot..."
    sleep 10
    echo ">>> CONTINUING after pause <<<"
fi

# Try to install dnsutils separately, ignore if it conflicts
echo "[CHROOT] Installing DNS utilities..."
echo -e "${YELLOW}Installing DNS utilities: host${NC}"
DNS_SUCCESS=0
DNS_FAILED=0
if apt -y install host; then
    echo -e "${GREEN}✓ host: SUCCESS${NC}"
    DNS_SUCCESS=1
    INSTALLED_PACKAGES+=(host)
else
    echo -e "${RED}✗ host: FAILED${NC}"
    DNS_FAILED=1
    FAILED_PACKAGES+=(host)
fi
if [ $DNS_FAILED -gt 0 ]; then
    echo ">>> PAUSING: DNS utilities failed <<<"
    echo "WARNING: DNS utilities failed."
    echo "Sleeping for 10 seconds to allow screenshot..."
    sleep 10
    echo ">>> CONTINUING after pause <<<"
fi

# Install system utilities and tools
echo "[CHROOT] Installing system utilities..."
SYS_PACKAGES=(bash-completion screen mc htop lsof ncdu tree pv zip unzip p7zip-full rsync lvm2 e2fsprogs ntfs-3g btrfs-progs)
echo -e "${YELLOW}Installing system utilities individually: ${SYS_PACKAGES[*]}${NC}"
SYS_SUCCESS=0
SYS_FAILED=0
for pkg in "${SYS_PACKAGES[@]}"; do
    echo -e "${YELLOW}Installing $pkg...${NC}"
    if apt -y install "$pkg"; then
        echo -e "${GREEN}✓ $pkg: SUCCESS${NC}"
        SYS_SUCCESS=$((SYS_SUCCESS + 1))
        INSTALLED_PACKAGES+=("$pkg")
    else
        echo -e "${RED}✗ $pkg: FAILED${NC}"
        SYS_FAILED=$((SYS_FAILED + 1))
        FAILED_PACKAGES+=("$pkg")
    fi
done
echo "System utilities: $SYS_SUCCESS/${#SYS_PACKAGES[@]} succeeded"
if [ $SYS_FAILED -gt 0 ]; then
    echo ">>> PAUSING: $SYS_FAILED system utilities failed <<<"
    echo "WARNING: $SYS_FAILED system utilities failed."
    echo "Sleeping for 10 seconds to allow screenshot..."
    sleep 10
    echo ">>> CONTINUING after pause <<<"
fi

# Install disk and filesystem tools  
echo "[CHROOT] Installing disk management tools..."
echo -e "${YELLOW}Installing disk tools: smartmontools hdparm testdisk${NC}"
DISK_SUCCESS=0
DISK_FAILED=0
echo -e "${YELLOW}Installing smartmontools...${NC}"
if apt -y install smartmontools; then
    echo -e "${GREEN}✓ smartmontools: SUCCESS${NC}"
    DISK_SUCCESS=$((DISK_SUCCESS + 1))
    INSTALLED_PACKAGES+=(smartmontools)
else
    echo -e "${RED}✗ smartmontools: FAILED${NC}"
    DISK_FAILED=$((DISK_FAILED + 1))
    FAILED_PACKAGES+=(smartmontools)
fi
echo -e "${YELLOW}Installing hdparm...${NC}"
if apt -y install hdparm; then
    echo -e "${GREEN}✓ hdparm: SUCCESS${NC}"
    DISK_SUCCESS=$((DISK_SUCCESS + 1))
    INSTALLED_PACKAGES+=(hdparm)
else
    echo -e "${RED}✗ hdparm: FAILED${NC}"
    DISK_FAILED=$((DISK_FAILED + 1))
    FAILED_PACKAGES+=(hdparm)
fi
echo -e "${YELLOW}Installing testdisk...${NC}"
if apt -y install testdisk; then
    echo -e "${GREEN}✓ testdisk: SUCCESS${NC}"
    DISK_SUCCESS=$((DISK_SUCCESS + 1))
    INSTALLED_PACKAGES+=(testdisk)
else
    echo -e "${RED}✗ testdisk: FAILED${NC}"
    DISK_FAILED=$((DISK_FAILED + 1))
    FAILED_PACKAGES+=(testdisk)
fi
echo "Disk tools: $DISK_SUCCESS/3 succeeded"
if [ $DISK_FAILED -gt 0 ]; then
    echo ">>> PAUSING: $DISK_FAILED disk tools failed <<<"
    echo "WARNING: $DISK_FAILED disk tools failed."
    echo "Sleeping for 10 seconds to allow screenshot..."
    sleep 10
    echo ">>> CONTINUING after pause <<<"
fi

# Install networking tools
echo "[CHROOT] Installing networking tools..."
echo -e "${YELLOW}Installing networking tools: nmap netcat-openbsd tcpdump traceroute iperf3 socat${NC}"
NET_SUCCESS=0
NET_FAILED=0
for pkg in nmap netcat-openbsd tcpdump traceroute iperf3 socat; do
    echo -e "${YELLOW}Installing $pkg...${NC}"
    if apt -y install "$pkg"; then
        echo -e "${GREEN}✓ $pkg: SUCCESS${NC}"
        NET_SUCCESS=$((NET_SUCCESS + 1))
        INSTALLED_PACKAGES+=("$pkg")
    else
        echo -e "${RED}✗ $pkg: FAILED${NC}"
        NET_FAILED=$((NET_FAILED + 1))
        FAILED_PACKAGES+=("$pkg")
    fi
done
echo "Networking tools: $NET_SUCCESS/6 succeeded"
if [ $NET_FAILED -gt 0 ]; then
    echo ">>> PAUSING: $NET_FAILED networking tools failed <<<"
    echo "WARNING: $NET_FAILED networking tools failed."
    echo "Sleeping for 10 seconds to allow screenshot..."
    sleep 10
    echo ">>> CONTINUING after pause <<<"
fi

# Try debootstrap and exfatprogs separately (might conflict)
echo "[CHROOT] Installing additional tools..."
ADD_SUCCESS=0
ADD_FAILED=0
echo -e "${YELLOW}Installing additional tools: debootstrap exfatprogs${NC}"
echo -e "${YELLOW}Installing debootstrap...${NC}"
if apt -y install debootstrap; then
    echo -e "${GREEN}✓ debootstrap: SUCCESS${NC}"
    ADD_SUCCESS=$((ADD_SUCCESS + 1))
    INSTALLED_PACKAGES+=(debootstrap)
else
    echo -e "${RED}✗ debootstrap: FAILED${NC}"
    ADD_FAILED=$((ADD_FAILED + 1))
    FAILED_PACKAGES+=(debootstrap)
fi
echo -e "${YELLOW}Installing exfatprogs...${NC}"
if apt -y install exfatprogs; then
    echo -e "${GREEN}✓ exfatprogs: SUCCESS${NC}"
    ADD_SUCCESS=$((ADD_SUCCESS + 1))
    INSTALLED_PACKAGES+=(exfatprogs)
else
    echo -e "${RED}✗ exfatprogs: FAILED${NC}"
    ADD_FAILED=$((ADD_FAILED + 1))
    FAILED_PACKAGES+=(exfatprogs)
fi
echo "Additional tools: $ADD_SUCCESS/2 succeeded"
if [ $ADD_FAILED -gt 0 ]; then
    echo ">>> PAUSING: $ADD_FAILED additional tools failed <<<"
    echo "WARNING: $ADD_FAILED additional tools failed."
    echo "Sleeping for 10 seconds to allow screenshot..."
    sleep 10
    echo ">>> CONTINUING after pause <<<"
fi

echo "[CHROOT] Installing sedutil-cli for SED drive management..."
# Download sedutil and extract archive
echo -e "${YELLOW}Installing sedutil-cli (manual installation from GitHub)${NC}"
SED_SUCCESS=0
SED_FAILED=0
if wget "https://github.com/Drive-Trust-Alliance/exec/blob/master/sedutil_LINUX.tgz?raw=true" -O sedutil_LINUX.tgz && \
   tar -xf sedutil_LINUX.tgz && \
   mv sedutil/Release_x86_64/sedutil-cli /usr/local/sbin/sedutil-cli && \
   chmod +x /usr/local/sbin/sedutil-cli; then
    echo -e "${GREEN}✓ sedutil-cli: SUCCESS${NC}"
    SED_SUCCESS=1
    INSTALLED_PACKAGES+=(sedutil-cli)
else
    echo -e "${RED}✗ sedutil-cli: FAILED${NC}"
    SED_FAILED=1
    FAILED_PACKAGES+=(sedutil-cli)
fi

# Clean up sedutil files
rm -rf ./sedutil* ./sedutil_LINUX.tgz 2>/dev/null || true

if [ $SED_FAILED -gt 0 ]; then
    echo ">>> PAUSING: sedutil-cli installation failed <<<"
    echo "WARNING: sedutil-cli installation failed."
    echo "Sleeping for 10 seconds to allow screenshot..."
    sleep 10
    echo ">>> CONTINUING after pause <<<"
fi

echo "[CHROOT] Configuring PATH to include sbin directories for all users..."
# Fix the PATH issue - regular users don't have /usr/local/sbin and /usr/sbin in PATH by default
# Modify /etc/profile to include sbin directories for all users
sed -i 's|PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games"|PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/games:/usr/games"|' /etc/profile

# Also add to bash.bashrc for interactive shells  
echo 'export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:$PATH"' >> /etc/bash.bashrc

# Update /etc/environment for systemd services
if [ -f /etc/environment ]; then
  if grep -q "^PATH=" /etc/environment; then
    sed -i 's|^PATH="\([^"]*\)"|PATH="/usr/local/sbin:/usr/local/bin:\1"|' /etc/environment
  else
    echo 'PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"' >> /etc/environment
  fi
else
  echo 'PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"' > /etc/environment
fi

# Also add for live user's bashrc
mkdir -p /home/user
echo 'export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:$PATH"' >> /home/user/.bashrc

# Create a symlink in /usr/bin for easier access (backup approach)
ln -sf /usr/local/sbin/sedutil-cli /usr/bin/sedutil-cli

echo "[+] PATH configuration completed - sedutil-cli and other sbin tools should now be accessible to all users"

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

echo "[CHROOT] Saving package installation results..."
# Write package lists to files so we can read them outside chroot

# Write to a persistent location that will survive chroot exit
# Use /var/tmp which is typically persistent, or create in root
echo "Installed packages:" > /var/tmp/package_results.txt

for pkg in "${INSTALLED_PACKAGES[@]}"; do
    echo "INSTALLED:$pkg" >> /var/tmp/package_results.txt
done

echo "Failed packages:" >> /var/tmp/package_results.txt
for pkg in "${FAILED_PACKAGES[@]}"; do
    echo "FAILED:$pkg" >> /var/tmp/package_results.txt
done

echo "Total installed: ${#INSTALLED_PACKAGES[@]}" >> /var/tmp/package_results.txt
echo "Total failed: ${#FAILED_PACKAGES[@]}" >> /var/tmp/package_results.txt

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
# PACKAGE INSTALLATION SUMMARY
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

echo
echo "========================================="
echo "          PACKAGE INSTALLATION SUMMARY"
echo "========================================="

# Read package results from the file created in chroot
INSTALLED_PACKAGES=()
FAILED_PACKAGES=()

if [ -f "edit/var/tmp/package_results.txt" ]; then
    echo "Reading package results from: edit/var/tmp/package_results.txt"
    echo "File contents:"
    # cat "edit/var/tmp/package_results.txt"
    echo "---"
    
    while IFS= read -r line; do
        if [[ "$line" == INSTALLED:* ]]; then
            pkg="${line#INSTALLED:}"
            INSTALLED_PACKAGES+=("$pkg")
        elif [[ "$line" == FAILED:* ]]; then
            pkg="${line#FAILED:}"
            FAILED_PACKAGES+=("$pkg")
        fi
    done < "edit/var/tmp/package_results.txt"
else
    echo "ERROR: No package results file found at edit/var/tmp/package_results.txt"
    echo "Available files in edit/var/tmp/:"
    ls -la edit/var/tmp/ 2>/dev/null || echo "Directory does not exist"
    echo "Available files in edit/tmp/:"
    ls -la edit/tmp/ 2>/dev/null || echo "Directory does not exist"
fi

echo
echo "✓ SUCCESSFULLY INSTALLED PACKAGES (${#INSTALLED_PACKAGES[@]}):"
if [ ${#INSTALLED_PACKAGES[@]} -gt 0 ]; then
    for pkg in "${INSTALLED_PACKAGES[@]}"; do
        echo "  ✓ $pkg"
    done
else
    echo "  (none detected)"
fi

echo
echo "✗ FAILED PACKAGES (${#FAILED_PACKAGES[@]}):"
if [ ${#FAILED_PACKAGES[@]} -gt 0 ]; then
    for pkg in "${FAILED_PACKAGES[@]}"; do
        echo "  ✗ $pkg"
    done
else
    echo "  (none detected)"
fi

TOTAL_ATTEMPTED=$((${#INSTALLED_PACKAGES[@]} + ${#FAILED_PACKAGES[@]}))
if [ $TOTAL_ATTEMPTED -gt 0 ]; then
    SUCCESS_RATE=$((${#INSTALLED_PACKAGES[@]} * 100 / TOTAL_ATTEMPTED))
else
    SUCCESS_RATE=0
fi

echo
echo "TOTAL ATTEMPTED: $TOTAL_ATTEMPTED"
echo "SUCCESS RATE: ${SUCCESS_RATE}%"
echo "========================================="
echo

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# USB WRITING
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

echo
echo "[*] Writing ISO to USB ($USBDEV)..."
echo "[*] This may take several minutes depending on USB speed..."
USB_START_TIME=$(date +%s)
dd if="$OUTISO" of="/dev/$USBDEV" bs=4M status=progress oflag=direct conv=fsync
sync
USB_END_TIME=$(date +%s)
USB_ELAPSED=$((USB_END_TIME - USB_START_TIME))
echo "[*] USB ($USBDEV) write completed in $((USB_ELAPSED / 60)) min $((USB_ELAPSED % 60)) sec"

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

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# ADDITIONAL USB CREATION LOOP
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

while true; do
  echo
  read -p "Create another USB? (y/n): " CREATE_ANOTHER
  
  case "$CREATE_ANOTHER" in
    [Yy]|[Yy][Ee][Ss])
      # Select new USB device
      while true; do
        echo
        echo "Select the target USB device to write the ISO to."
        echo "Make sure to choose the correct device as all data on it will be erased!"
        echo
        echo "Available local drives:"
        lsblk -d -o NAME,SIZE,MODEL,TYPE,MOUNTPOINT | grep -E 'disk' | grep -vi $BOOTDEV
        echo
        
        read -p "Enter the device to write ISO to (e.g., sdb, nvme0n1): " NEW_USBDEV
        
        # Check if entered device is in the lsblk output and is a disk
        if lsblk -d -o NAME,TYPE | grep -E "^$NEW_USBDEV\\s+disk" > /dev/null; then
          # Prevent wiping the boot device
          if [[ "$NEW_USBDEV" == "$BOOTDEV" ]]; then
            echo
            echo "ERROR: /dev/$NEW_USBDEV appears to be the boot device. Please choose another device."
            read -p "Press Enter to continue..."
            clear
            continue
          fi
          break
        fi
        echo
        echo "Device /dev/$NEW_USBDEV is not a valid local disk from the list above. Please try again."
        read -p "Press Enter to continue..."
        clear
      done
      
      # Write ISO to new USB device
      echo
      echo "[*] Writing ISO to USB ($NEW_USBDEV)..."
      echo "[*] This may take several minutes depending on USB speed..."
      USB_START_TIME=$(date +%s)
      dd if="$OUTISO" of="/dev/$NEW_USBDEV" bs=4M status=progress oflag=direct conv=fsync
      sync
      USB_END_TIME=$(date +%s)
      USB_ELAPSED=$((USB_END_TIME - USB_START_TIME))
      
      echo
      echo "[*] USB ($NEW_USBDEV) flashing completed successfully!"
      echo "[*] USB ($NEW_USBDEV) write completed in $((USB_ELAPSED / 60)) min $((USB_ELAPSED % 60)) sec"
      ;;
    [Nn]|[Nn][Oo])
      echo
      echo "[*] No additional USBs will be created."
      break
      ;;
    *)
      echo
      echo "Please answer yes (y) or no (n)."
      ;;
  esac
done