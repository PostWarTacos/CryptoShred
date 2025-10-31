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

# Color definitions for installation messages
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# FUNCTION DEFINITIONS
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

# Function to get remote blob SHA from GitHub API
get_remote_blob_sha() {
  # arg1 = api url
  curl "${CURL_OPTS[@]}" "${AUTH_HDR[@]}" -H "Accept: application/vnd.github.v3+json" "$1" 2>/dev/null \
    | sed -n 's/.*"sha": *"\([^"]*\)".*/\1/p' || true
}

# Safe file installation function
# Usage: safe_install_file "source_file" "target_file" ["permissions"]
safe_install_file() {
  local source="$1"
  local target="$2"
  local perms="${3:-0755}"
  
  mkdir -p "$(dirname "$target")" || { echo -e "${RED}[!] Failed to create directory for $target.${NC}"; return 1; }
  cp -- "$source" "$target" || { echo -e "${RED}[!] Copy failed to $target.${NC}"; return 1; }
  chmod "$perms" "$target" || true
  sync "$target" || true
  return 0
}

# Download and validate function with Git blob SHA verification
# Usage: download_and_validate "api_url" "raw_url" "target_file" "workspace_mode" ["exit_on_update"]
# workspace_mode: "true" for workspace-only install, "false" for host system install
# exit_on_update: "true" to exit script after successful update (for self-update)
download_and_validate() {
  local api_url="$1"
  local raw_url="$2" 
  local target_file="$3"
  local workspace_mode="${4:-false}"
  local exit_on_update="${5:-false}"
  local script_name="$(basename "$target_file")"
  
  echo -e "${YELLOW}[*] Checking remote $script_name for updates...${NC}"
  
  # Get remote and local blob SHAs
  local remote_sha="$(get_remote_blob_sha "$api_url")"
  local local_blob=""
  if command -v git >/dev/null 2>&1 && [ -f "$target_file" ]; then
    local_blob=$(git hash-object "$target_file" 2>/dev/null || true)
  fi
  
  # Check if up to date
  if [ -n "$remote_sha" ] && [ -n "$local_blob" ] && [ "$remote_sha" = "$local_blob" ]; then
    echo -e "${GREEN}[+] Local $script_name is up to date (git blob sha match).${NC}"
    return 0
  fi
  
  echo -e "${YELLOW}[*] Remote $script_name differs or verification unavailable; downloading for validation...${NC}"
  local tmp_file="$(mktemp)" || { echo -e "${RED}[!] Failed to create temp file.${NC}"; return 1; }
  
  # Download file
  if ! curl "${CURL_OPTS[@]}" -o "$tmp_file" "$raw_url"; then
    echo -e "${RED}[!] Failed to download $script_name from $raw_url.${NC}"
    rm -f "$tmp_file"
    return 1
  fi
  
  # Basic sanity check for shell scripts
  if [[ "$script_name" == *.sh ]] && ! sed -n '1p' "$tmp_file" | grep -qE '^#!.*/bin/(ba)?sh'; then
    echo -e "${RED}[!] Downloaded $script_name missing valid shebang. Rejecting.${NC}"
    rm -f "$tmp_file"
    return 1
  fi
  
  # Git blob SHA verification (preferred)
  if [ -n "$remote_sha" ] && command -v git >/dev/null 2>&1; then
    local dl_blob="$(git hash-object "$tmp_file" 2>/dev/null || true)"
    if [ -n "$dl_blob" ] && [ "$dl_blob" = "$remote_sha" ]; then
      echo -e "${GREEN}[+] Download validated against GitHub API blob SHA.${NC}"
      
      # Install based on mode
      if [ "$workspace_mode" = "true" ]; then
        # Workspace-only installation
        if safe_install_file "$tmp_file" "$target_file" "0755"; then
          echo -e "${GREEN}[+] $script_name downloaded to $target_file (will be embedded into ISO).${NC}"
          rm -f "$tmp_file"
          return 0
        else
          rm -f "$tmp_file"
          return 1
        fi
      else
        # Host system installation with permission preservation
        local orig_perms=$(stat -c %a "$target_file" 2>/dev/null || echo 0755)
        chmod +x "$tmp_file" || true
        if command -v install >/dev/null 2>&1; then
          install -m "$orig_perms" "$tmp_file" "$target_file" || {
            echo -e "${RED}[!] Install failed. Exiting.${NC}"
            rm -f "$tmp_file"
            return 1
          }
        else
          if ! safe_install_file "$tmp_file" "$target_file" "$orig_perms"; then
            rm -f "$tmp_file"
            return 1
          fi
        fi
        sync "$target_file" || true
        echo -e "${GREEN}[+] Script updated from GitHub (verified). Please re-run $script_name.${NC}"
        rm -f "$tmp_file"
        
        # Exit if this is a self-update
        if [ "$exit_on_update" = "true" ]; then
          exit 0
        fi
        return 0
      fi
    else
      echo -e "${RED}[!] Download blob SHA mismatch (expected ${remote_sha:-<none>}). Rejecting.${NC}"
      echo "    Downloaded: ${dl_blob:-<missing>}"
      rm -f "$tmp_file"
    fi
  fi
  
  # Fallback: SHA256 verification
  echo -e "${YELLOW}[*] Falling back to SHA256 verification...${NC}"
  local remote_hash=$(sha256sum "$tmp_file" | cut -d' ' -f1)
  local local_hash=$([ -f "$target_file" ] && sha256sum "$target_file" | cut -d' ' -f1 || echo "")
  
  if [ -z "$remote_hash" ]; then
    echo -e "${RED}[!] Could not compute remote sha256. Rejecting download.${NC}"
    rm -f "$tmp_file"
    return 1
  elif [ -z "$local_hash" ] || [ "$local_hash" != "$remote_hash" ]; then
    if [ "$workspace_mode" = "true" ]; then
      echo -e "${YELLOW}[*] sha256 differs or local missing; downloading $script_name for workspace...${NC}"
      if safe_install_file "$tmp_file" "$target_file" "0755"; then
        echo -e "${GREEN}[+] $script_name downloaded to $target_file (will be embedded into ISO).${NC}"
        rm -f "$tmp_file"
        return 0
      else
        rm -f "$tmp_file"
        return 1
      fi
    else
      echo -e "${YELLOW}[*] sha256 differs or local missing; updating $script_name...${NC}"
      local orig_perms=$(stat -c %a "$target_file" 2>/dev/null || echo 0755)
      chmod +x "$tmp_file" || true
      if command -v install >/dev/null 2>&1; then
        install -m "$orig_perms" "$tmp_file" "$target_file" || {
          echo -e "${RED}[!] Install failed.${NC}"
          rm -f "$tmp_file"
          return 1
        }
      else
        if ! safe_install_file "$tmp_file" "$target_file" "$orig_perms"; then
          rm -f "$tmp_file"
          return 1
        fi
      fi
      sync "$target_file" || true
      echo -e "${GREEN}[+] $script_name updated.${NC}"
      rm -f "$tmp_file"
      
      # Exit if this is a self-update
      if [ "$exit_on_update" = "true" ]; then
        exit 0
      fi
      return 0
    fi
  else
    echo -e "${GREEN}[+] Downloaded $script_name matches local sha256; no update needed.${NC}"
    rm -f "$tmp_file"
    return 0
  fi
}

# Resolve the path to this script (attempt a few strategies)
resolve_self_path() {
  local path
  # If $0 is absolute and exists, use it
  if [[ "$0" == /* ]] && [ -f "$0" ]; then
    printf '%s' "$0"
    return 0
  fi
  # Prefer BASH_SOURCE if it is absolute
  if [ -n "${BASH_SOURCE[0]:-}" ] && [[ "${BASH_SOURCE[0]}" == /* ]] && [ -f "${BASH_SOURCE[0]}" ]; then
    printf '%s' "${BASH_SOURCE[0]}"
    return 0
  fi
  # Try realpath/readlink if available
  if command -v realpath >/dev/null 2>&1; then
    realpath "${BASH_SOURCE[0]:-$0}" 2>/dev/null && return 0
  fi
  if command -v readlink >/dev/null 2>&1; then
    readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null && return 0
  fi
  # Fallback: construct from pwd + basename
  printf '%s' "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null || pwd)/$(basename "${BASH_SOURCE[0]:-$0}")"
}

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
  echo -e "${GREEN}[+] Time End: $END_TS"
  echo -e "${GREEN}[+] Time Elapsed: ${YELLOW}$((ELAPSED / 60)) min $((ELAPSED % 60)) sec${NC}"
}
trap finish EXIT

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# DEPENDENCY VERIFICATION
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

# === Verify required tools are installed on local host ===
echo
echo "${YELLOW}[*] Checking for required tools...${NC}"
for cmd in cryptsetup 7z unsquashfs xorriso wget curl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo
    echo "${RED}[!] $cmd is not installed. Attempting to install...${NC}"
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
      echo "${RED}[!] Failed to install $cmd. Please install it manually.${NC}"
      read -p "Press Enter to continue..."
      exit 1
    fi
  fi
done

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# UPDATE CHECKING
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

# GitHub repo info for self-update
GITHUB_OWNER="PostWarTacos"
GITHUB_REPO="CryptoShred"
BUILD_REMOTE_PATH="BuildCryptoShred.sh"
REF="main"

# API and raw URLs
API_URL="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/contents/${BUILD_REMOTE_PATH}?ref=${REF}"
RAW_URL="https://raw.githubusercontent.com/${GITHUB_OWNER}/${GITHUB_REPO}/${REF}/${BUILD_REMOTE_PATH}"

# Hardened curl options
CURL_OPTS=( --fail --silent --show-error --location --connect-timeout 10 --max-time 300 --retry 3 --retry-delay 2 )

# Allow token via environment to avoid rate limits / access private repos
AUTH_HDR=()
if [ -n "${GITHUB_TOKEN:-}" ]; then
  AUTH_HDR=( -H "Authorization: token ${GITHUB_TOKEN}" )
fi

SCRIPT_PATH="$(resolve_self_path)"
# Fallback: if resolution failed, use $0 as-is
if [ -z "$SCRIPT_PATH" ] || [ ! -f "$SCRIPT_PATH" ]; then
  SCRIPT_PATH="$0"
fi

echo
echo -e "${YELLOW}[*] Checking for BuildCryptoShred.sh updates using GitHub API blob SHA...${NC}"

# Use the download and validate function for self-update
if download_and_validate "$API_URL" "$RAW_URL" "$SCRIPT_PATH" "false" "true"; then
  # If function returns 0 but file was updated, it will have already exited
  # If we get here, either file is up to date or there was an error that we can continue from
  echo -e "${GREEN}[+] BuildCryptoShred.sh check completed.${NC}"
else
  echo -e "${YELLOW}[*] Could not update BuildCryptoShred.sh, continuing with current version.${NC}"
fi

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# INTRODUCTION AND USER CONFIRMATION
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

echo
echo "================================================== CryptoShred ISO Builder =================================================="
echo
echo -e "${GREEN}CryptoShred ISO Builder - Create a bootable Debian-based ISO with CryptoShred pre-installed${NC}"
echo "Version 1.8 - 2025-10-29"
echo
echo "This script will create a bootable Debian-based ISO with CryptoShred.sh pre-installed and configured to run on first boot."
echo "The resulting ISO will be written directly to the specified USB device."
echo "Make sure to change the USB device and script are in place before proceeding."
echo "WARNING: This will ERASE ALL DATA on the specified USB device."
echo
echo -e "${RED}IMPORTANT!!! Make sure your target USB device (device to have Debian/CryptoShred ISO installed) is plugged in.${NC}"
echo
echo "============================================================================================================================="
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
  echo -e "${RED}Make sure to choose the correct device as all data on it will be erased!${NC}"
  echo
  echo -e "${YELLOW}Available local drives:${NC}"
  lsblk -d -o NAME,SIZE,MODEL,TYPE,MOUNTPOINT | grep -E 'disk' | grep -vi "$BOOTDEV"
  echo
  # Prompt for device to write ISO to
  read -p "Enter the device to write ISO to (e.g., sdb, nvme0n1): " USBDEV
  # Check if entered device is in the lsblk output and is a disk
  if lsblk -d -o NAME,TYPE | grep -E "^$USBDEV\s+disk" > /dev/null; then
    # Prevent wiping the boot device
    if [[ "$USBDEV" == "$BOOTDEV" ]]; then
      echo
      echo -e "${RED}ERROR: /dev/$USBDEV appears to be the boot device. Please choose another device.${NC}"
      read -p "Press Enter to continue..."
      clear
      continue
    fi
    break
  fi
  echo
  echo -e "${RED}Device /dev/$USBDEV is not a valid local disk from the list above. Please try again.${NC}"
  read -p "Press Enter to continue..."
  clear
done

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# WORKSPACE PREPARATION
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

echo
echo -e "${YELLOW}[*] Cleaning old build dirs...${NC}"
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
  echo "${RED}[!] Using fallback script directory: $SCRIPT_DIR${NC}"
fi

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# DOWNLOAD OR UPDATE CRYPTOSHRED.SH (validated via GitHub API blob SHA)
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

# Ensure LOCAL_CRYPTOSHRED points to the intended local path
LOCAL_CRYPTOSHRED="${LOCAL_CRYPTOSHRED:-$CRYPTOSHRED_SCRIPT}"

# Remote info for the CryptoShred script
CRYPTOSHRED_REMOTE_PATH="CryptoShred.sh"
CRYPTOSHRED_API_URL="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/contents/${CRYPTOSHRED_REMOTE_PATH}?ref=${REF}"
CRYPTOSHRED_RAW_URL="https://raw.githubusercontent.com/${GITHUB_OWNER}/${GITHUB_REPO}/${REF}/${CRYPTOSHRED_REMOTE_PATH}"

echo
# Use the download and validate function for CryptoShred.sh (workspace mode)
if ! download_and_validate "$CRYPTOSHRED_API_URL" "$CRYPTOSHRED_RAW_URL" "$LOCAL_CRYPTOSHRED" "true"; then
  echo -e "${RED}[!] Failed to download/validate CryptoShred.sh. Checking for local copy...${NC}"
  
  # Check if we have a local copy we can use
  if [ ! -f "$LOCAL_CRYPTOSHRED" ]; then
    echo -e "${RED}[!] No local CryptoShred.sh found. Cannot continue without the script.${NC}"
    exit 1
  else
    echo -e "${YELLOW}[*] Using existing local CryptoShred.sh copy.${NC}"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# DEBIAN ISO DOWNLOAD
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

echo
echo -e "${YELLOW}[*] Fetching latest Debian ISO link...${NC}"
ISO_URL=$(curl -s "https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid/" | 
  grep -oP 'href="debian-live-[0-9.]+-amd64-standard\.iso"' | head -n1 | cut -d'"' -f2)

# Check if ISO_URL was found
if [ -z "$ISO_URL" ]; then
  echo -e "${RED}[!] Error: Could not find Debian ISO URL. Check internet connection or Debian mirrors.${NC}"
  echo "[DEBUG] Trying to list available ISOs..."
  curl -s "https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid/" | grep -o 'debian-live-[^"]*\.iso' | head -5
  exit 1
fi

echo -e "${YELLOW}[*] Found ISO: $ISO_URL${NC}"
echo -e "${YELLOW}[*] Downloading $ISO_URL...${NC}"
echo -e "${YELLOW}[*] This may take several minutes depending on your connection...${NC}"

# Use wget with better progress display and error handling
if ! wget --progress=bar:force "https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid/$ISO_URL" -O debian.iso; then
  echo -e "${RED}[!] Error: Failed to download Debian ISO${NC}"
  echo -e "${RED}[!] Please check your internet connection and try again${NC}"
  exit 1
fi

echo -e "${GREEN}[+] ISO download completed successfully${NC}"

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# ISO EXTRACTION AND MODIFICATION
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

echo
echo
echo -e "${YELLOW}[*] Extracting ISO...${NC}"
7z x debian.iso -oiso >/dev/null

# Extract squashfs
echo
echo -e "${YELLOW}[*] Extracting squashfs...${NC}"
unsquashfs iso/live/filesystem.squashfs
mv squashfs-root/* edit
rm -rf squashfs-root

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# CRYPTOSHRED INTEGRATION
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

echo -e "${YELLOW}[*] Copying CryptoShred.sh to usr/bin...${NC}"
if [ ! -f "$CRYPTOSHRED_SCRIPT" ]; then
  echo
  echo -e "${RED}[!] $CRYPTOSHRED_SCRIPT not found. Aborting.${NC}"
  exit 1
fi
mkdir -p edit/usr/bin
cp -- "$CRYPTOSHRED_SCRIPT" "edit/usr/bin/CryptoShred.sh"
chmod 755 "edit/usr/bin/CryptoShred.sh"

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# SYSTEMD SERVICE CREATION
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

echo
echo -e "${YELLOW}[*] Creating CryptoShred service...${NC}"
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
echo -e "${YELLOW}[*] Mounting for chroot...${NC}"
mount --bind /dev edit/dev
mount --bind /run edit/run
mount -t proc /proc edit/proc
mount -t sysfs /sys edit/sys
mount -t tmpfs tmpfs edit/tmp
mount -t devpts /dev/pts edit/dev/pts

# Setup networking for chroot
echo
echo
echo -e "${YELLOW}[*] Setting up networking for chroot...${NC}"
cp /etc/resolv.conf edit/etc/resolv.conf
cat > edit/etc/apt/sources.list <<'EOF'
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
EOF


# === Chroot and install cryptsetup ===
echo
echo
echo -e "${YELLOW}[*] Chrooting and installing cryptsetup...${NC}"
cat <<'CHROOT' | chroot edit /bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get -y full-upgrade
apt-get -y install wget ca-certificates cryptsetup

echo "[*] Installing sedutil-cli for SED drive management..."
# Download sedutil and extract archive
echo "[*] Downloading sedutil-cli..."
if ! wget "https://github.com/Drive-Trust-Alliance/exec/blob/master/sedutil_LINUX.tgz?raw=true" -O sedutil_LINUX.tgz; then
  echo "[!] Warning: Failed to download sedutil-cli. Continuing without it."
else
  echo "[*] Extracting sedutil-cli..."
  tar -xf sedutil_LINUX.tgz
  
  # Check which directory structure exists (case-sensitive)
  if [ -f "sedutil/Release_x86_64/sedutil-cli" ]; then
    mv sedutil/Release_x86_64/sedutil-cli /usr/local/sbin/sedutil-cli
  elif [ -f "sedutil/release_x86_64/sedutil-cli" ]; then
    mv sedutil/release_x86_64/sedutil-cli /usr/local/sbin/sedutil-cli
  else
    echo "[!] Warning: sedutil-cli binary not found in expected location. Listing contents:"
    find sedutil/ -name "sedutil-cli" -type f 2>/dev/null || echo "No sedutil-cli found"
    echo "[!] Continuing without sedutil-cli..."
  fi
  
  # Make executable if it exists
  if [ -f "/usr/local/sbin/sedutil-cli" ]; then
    chmod +x /usr/local/sbin/sedutil-cli
    echo "[+] sedutil-cli installed successfully"
  fi
  
  # Clean up sedutil files
  rm -rf ./sedutil* ./sedutil_LINUX.tgz
fi

echo "[*] Configuring PATH to include /usr/local/sbin for all users..."
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

# Create a symlink in /usr/bin for easier access (backup approach)
ln -sf /usr/local/sbin/sedutil-cli /usr/bin/sedutil-cli

echo "[+] PATH configuration completed - sedutil-cli should now be accessible to all users"

apt-get clean

exit
CHROOT

# Cleanup mounts
echo
echo -e "${YELLOW}[*] Cleaning up mounts...${NC}"
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
echo -e "${YELLOW}[*] Modifying GRUB config...${NC}"
GRUB_CFG="iso/boot/grub/grub.cfg"
if [ -f "$GRUB_CFG" ]; then
  sed -i '1i set default=0\nset timeout=0' "$GRUB_CFG"
else
  echo -e "${RED}[!] GRUB config not found at $GRUB_CFG${NC}"
  read -p "Press Enter to continue..."
  exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# SQUASHFS REBUILD
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

echo
echo -e "${YELLOW}[*] Rebuilding squashfs...${NC}"
mksquashfs edit iso/live/filesystem.squashfs -noappend -e boot

# Verify the cryptoshred service and its enablement symlink exist in the edit tree
if [ ! -f "edit/etc/systemd/system/cryptoshred.service" ] || [ ! -L "edit/etc/systemd/system/sysinit.target.wants/cryptoshred.service" ]; then
  echo
  echo -e "${RED}[!] cryptoshred.service or its enablement symlink is missing from the edit tree after squashfs rebuild.${NC}"
  echo -e "${RED}[!] Please check edit/etc/systemd/system and edit/etc/systemd/system/sysinit.target.wants${NC}"
  exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# ISO BUILDING
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

echo
echo -e "${YELLOW}[*] Building ISO...${NC}"
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
    echo -e "${YELLOW}[*] Using isohybrid MBR from: $cand${NC}"
    break
  fi
done
if [ -z "${ISOHYBRID_MBR_OPT[*]:-}" ]; then
  echo -e "${RED}[!] isohdpfx.bin not found in known locations; proceeding without -isohybrid-mbr.${NC}"
  echo -e "${RED}[!] This may affect BIOS bootability on some systems.${NC}"
fi

# Build the ISO. Use the computed ISOHYBRID_MBR_OPT (may be empty).
ISO_ROOT="$WORKDIR/iso"
if [ ! -d "$ISO_ROOT" ]; then
  echo -e "${RED}[!] ISO root directory not found at $ISO_ROOT${NC}"
  exit 1
fi

# Check isolinux files; if missing, skip BIOS isolinux options (ISO will still have EFI boot if present)
ISOLINUX_OPTIONS=()
if [ -f "$ISO_ROOT/isolinux/isolinux.bin" ] && [ -f "$ISO_ROOT/isolinux/boot.cat" ]; then
  ISOLINUX_OPTIONS=( -c isolinux/boot.cat -b isolinux/isolinux.bin -no-emul-boot -boot-load-size 4 -boot-info-table )
else
  echo -e "${RED}[!] isolinux/isolinux.bin or isolinux/boot.cat not found in $ISO_ROOT; skipping isolinux BIOS options.${NC}"
fi

# Check EFI image
EFI_OPT=()
if [ -f "$ISO_ROOT/boot/grub/efi.img" ]; then
  EFI_OPT=( -eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot -isohybrid-gpt-basdat )
else
  echo -e "${RED}[!] EFI image boot/grub/efi.img not found in $ISO_ROOT; skipping EFI options.${NC}"
fi

# Build argument array safely and run xorriso
XORRISO_ARGS=( -as mkisofs -o "$OUTISO" -r -V "CryptoShred" -J -l -iso-level 3 -partition_offset 16 -A "CryptoShred" )
if [ -n "${ISOHYBRID_MBR_OPT[*]:-}" ]; then
  XORRISO_ARGS+=( "${ISOHYBRID_MBR_OPT[@]}" )
fi
XORRISO_ARGS+=( "${ISOLINUX_OPTIONS[@]}" )
XORRISO_ARGS+=( "${EFI_OPT[@]}" )
XORRISO_ARGS+=( "$ISO_ROOT" )

echo -e "${YELLOW}[*] Running: xorriso ${XORRISO_ARGS[*]}${NC}"
xorriso "${XORRISO_ARGS[@]}"

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# USB WRITING
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

echo
echo -e "${YELLOW}[*] Writing ISO to USB ($USBDEV)...${NC}"
echo -e "${YELLOW}[*] This may take several minutes depending on USB speed...${NC}"
USB_START_TIME=$(date +%s)
dd if="$OUTISO" of="/dev/$USBDEV" bs=4M status=progress oflag=direct conv=fsync
sync
USB_END_TIME=$(date +%s)
USB_ELAPSED=$((USB_END_TIME - USB_START_TIME))
FIRST_USB_ELAPSED=$((USB_END_TIME - START_TIME))
echo -e "${GREEN}[+] USB ($USBDEV) write completed in ${YELLOW}$((USB_ELAPSED / 60)) min $((USB_ELAPSED % 60)) sec${NC}"
echo -e "${GREEN}[+] Script was started at: ${YELLOW}$(date -d "@$START_TIME" '+%Y-%m-%d %H:%M:%S'). ${GREEN}Total elapsed time for first USB: ${YELLOW}$((FIRST_USB_ELAPSED / 60)) min $((FIRST_USB_ELAPSED % 60)) sec${NC}"

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# ADDITIONAL USB CREATION LOOP
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

while true; do
  echo
  printf "%b" "${YELLOW}Create another USB? (y/n): ${NC}"
  read -r CREATE_ANOTHER
  
  case "$CREATE_ANOTHER" in
    [Yy]|[Yy][Ee][Ss])
      # Select new USB device
      while true; do
        echo
        echo "Select another USB device to write the same ISO to.${NC}"
        echo -e "${RED}Make sure to choose the correct device as all data on it will be erased!${NC}"
        echo
        echo -e "${YELLOW}Available local drives:${NC}"
        lsblk -d -o NAME,SIZE,MODEL,TYPE,MOUNTPOINT | grep -E 'disk' | grep -vi $BOOTDEV
        echo
        
        read -p "Enter the device to write ISO to (e.g., sdb, nvme0n1): " NEW_USBDEV
        
        # Check if entered device is in the lsblk output and is a disk
        if lsblk -d -o NAME,TYPE | grep -E "^$NEW_USBDEV\\s+disk" > /dev/null; then
          # Prevent wiping the boot device
          if [[ "$NEW_USBDEV" == "$BOOTDEV" ]]; then
            echo
            echo -e "${RED}ERROR: /dev/$NEW_USBDEV appears to be the boot device. Please choose another device.${NC}"
            read -p "Press Enter to continue..."
            continue
          fi
          break
        fi
        echo
        echo -e "${RED}Device /dev/$NEW_USBDEV is not a valid local disk from the list above. Please try again.${NC}"
        read -p "Press Enter to continue..."
      done
      
      # Write ISO to new USB device
      echo
      echo -e "${YELLOW}[*] Writing ISO to USB ($NEW_USBDEV)...${NC}"
      echo -e "${YELLOW}[*] This may take several minutes depending on USB speed...${NC}"
      USB_START_TIME=$(date +%s)
      dd if="$OUTISO" of="/dev/$NEW_USBDEV" bs=4M status=progress oflag=direct conv=fsync
      sync
      USB_END_TIME=$(date +%s)
      USB_ELAPSED=$((USB_END_TIME - USB_START_TIME))
      THIS_USB_ELAPSED=$((USB_END_TIME - START_TIME))
      echo
      echo -e "${GREEN}[+] USB ($NEW_USBDEV) flashing completed successfully!${NC}"
      echo -e "${GREEN}[+] USB ($NEW_USBDEV) write completed in ${YELLOW}$((USB_ELAPSED / 60)) min $((USB_ELAPSED % 60)) sec${NC}"
      echo -e "${GREEN}[+] Script was started at: ${YELLOW}$(date -d "@$START_TIME" '+%Y-%m-%d %H:%M:%S'). ${GREEN}Total elapsed time for THIS USB: ${YELLOW}$((THIS_USB_ELAPSED / 60)) min $((THIS_USB_ELAPSED % 60)) sec${NC}"
      ;;
    [Nn]|[Nn][Oo])
      echo
      echo -e "${GREEN}[+] No additional USBs will be created.${NC}"
      break
      ;;
    *)
      echo
      echo "Please answer yes (y) or no (n)."
      ;;
  esac
done