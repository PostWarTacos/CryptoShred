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

# Compute local hashes
LOCAL_BLOB_SHA=""
if command -v git >/dev/null 2>&1 && [ -f "$SCRIPT_PATH" ]; then
  LOCAL_BLOB_SHA=$(git hash-object "$SCRIPT_PATH" 2>/dev/null || true)
fi
LOCAL_SHA256=$([ -f "$SCRIPT_PATH" ] && sha256sum "$SCRIPT_PATH" | cut -d' ' -f1 || echo "")

echo
echo -e "${YELLOW}[*] Checking for BuildCryptoShred.sh updates using GitHub API blob SHA...${NC}"

# Fetch remote blob SHA from GitHub API
REMOTE_SHA="$(get_remote_blob_sha "$API_URL")"

# If we have a git blob SHA locally and remotely, compare directly
if [ -n "$LOCAL_BLOB_SHA" ] && [ -n "$REMOTE_SHA" ]; then
  if [ "$LOCAL_BLOB_SHA" = "$REMOTE_SHA" ]; then
    echo -e "${GREEN}[+] BuildCryptoShred.sh is up to date (git blob sha match: ${LOCAL_BLOB_SHA:0:16}...)${NC}"
  else
    echo
    echo -e "${RED}[!] Local script blob SHA differs from GitHub API blob SHA.${NC}"
    echo "    Local blob SHA:  ${LOCAL_BLOB_SHA}"
    echo "    Remote blob SHA: ${REMOTE_SHA}"
    echo "    Downloading and verifying remote script..."

    TMP_REMOTE="$(mktemp)" || { echo -e "${RED}[!] Failed to create temp file.${NC}"; exit 1; }
    if ! curl "${CURL_OPTS[@]}" -o "$TMP_REMOTE" "$RAW_URL"; then
      echo -e "${RED}[!] Failed to download remote script from $RAW_URL. Aborting update.${NC}"
      rm -f "$TMP_REMOTE"
    else
      # Compute blob SHA of downloaded file and verify matches API
      DOWNLOADED_BLOB_SHA=$(git hash-object "$TMP_REMOTE" 2>/dev/null || true)
      if [ -n "$DOWNLOADED_BLOB_SHA" ] && [ "$DOWNLOADED_BLOB_SHA" = "$REMOTE_SHA" ]; then
        echo -e "${GREEN}[+] Download verified against GitHub API blob SHA.${NC}"
        # Replace current script atomically, preserving original permissions
        ORIG_PERMS=$(stat -c %a "$SCRIPT_PATH" 2>/dev/null || echo 0755)
        chmod +x "$TMP_REMOTE" || true
        if command -v install >/dev/null 2>&1; then
          install -m "$ORIG_PERMS" "$TMP_REMOTE" "$SCRIPT_PATH" || {
            echo -e "${RED}[!] Install failed. Exiting.${NC}"
            rm -f "$TMP_REMOTE"
            exit 1
          }
        else
          mkdir -p "$(dirname "$SCRIPT_PATH")"
          cp -- "$TMP_REMOTE" "$SCRIPT_PATH" || {
            echo -e "${RED}[!] Copy failed. Exiting.${NC}"
            rm -f "$TMP_REMOTE"
            exit 1
          }
          chmod "$ORIG_PERMS" "$SCRIPT_PATH" || true
        fi
        sync "$SCRIPT_PATH" || true
        echo
        echo -e "${GREEN}[+] Script updated from GitHub (verified). Please re-run BuildCryptoShred.sh.${NC}"
        rm -f "$TMP_REMOTE"
        exit 0
      else
        echo -e "${RED}[!] Downloaded file failed verification (blob sha mismatch). Not updating.${NC}"
        echo "    Downloaded blob SHA: ${DOWNLOADED_BLOB_SHA:-<missing>}"
        echo "    Expected remote API blob SHA: ${REMOTE_SHA:-<missing>}"
        rm -f "$TMP_REMOTE"
      fi
    fi
  fi

# If we couldn't compute local blob SHA or couldn't fetch REMOTE_SHA, fall back to sha256-based check
else
  echo -e "${YELLOW}[*] Falling back to sha256-based check (git blob sha unavailable or API failed).${NC}"
  TMP_REMOTE="$(mktemp)" || { echo -e "${RED}[!] Failed to create temp file.${NC}"; exit 1; }
  if curl "${CURL_OPTS[@]}" -o "$TMP_REMOTE" "$RAW_URL"; then
    REMOTE_HASH=$(sha256sum "$TMP_REMOTE" | cut -d' ' -f1)
    LOCAL_HASH=$([ -f "$SCRIPT_PATH" ] && sha256sum "$SCRIPT_PATH" | cut -d' ' -f1 || echo "")
    if [ -z "$REMOTE_HASH" ]; then
      echo -e "${RED}[!] Could not compute remote sha256. Skipping update.${NC}"
      rm -f "$TMP_REMOTE"
    elif [ "$LOCAL_HASH" != "$REMOTE_HASH" ]; then
      echo
      echo -e "${RED}[!] Local script sha256 differs from remote version.${NC}"
      echo "    Local:  ${LOCAL_HASH:-<missing>}"
      echo "    Remote: ${REMOTE_HASH:-<unknown>}"
      echo "    Updating local script with the latest version..."
      ORIG_PERMS=$(stat -c %a "$SCRIPT_PATH" 2>/dev/null || echo 0755)
      chmod +x "$TMP_REMOTE" || true
      if command -v install >/dev/null 2>&1; then
        install -m "$ORIG_PERMS" "$TMP_REMOTE" "$SCRIPT_PATH" || {
          echo -e "${RED}[!] Install failed. Exiting script.${NC}"
          rm -f "$TMP_REMOTE"
          exit 1
        }
      else
        mkdir -p "$(dirname "$SCRIPT_PATH")"
        cp -- "$TMP_REMOTE" "$SCRIPT_PATH" || {
          echo -e "${RED}[!] Copy failed. Exiting script.${NC}"
          rm -f "$TMP_REMOTE"
          exit 1
        }
        chmod "$ORIG_PERMS" "$SCRIPT_PATH" || true
      fi
      sync "$SCRIPT_PATH" || true
      echo
      echo -e "${GREEN}[+] Script updated. Please re-run BuildCryptoShred.sh.${NC}"
      rm -f "$TMP_REMOTE"
      exit 0
    else
      echo -e "${GREEN}[+] BuildCryptoShred.sh is up to date (sha256 match: ${LOCAL_HASH:0:16}...)${NC}"
      rm -f "$TMP_REMOTE"
    fi
  else
    echo -e "${RED}[!] Could not download remote script for comparison. Continuing with local version.${NC}"
    rm -f "$TMP_REMOTE"
  fi
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
echo -e "${YELLOW}[*] Checking remote CryptoShred.sh for updates...${NC}"

REMOTE_CRYPT_SHA="$(get_remote_blob_sha "$CRYPTOSHRED_API_URL")"
LOCAL_CRYPT_BLOB=""
if command -v git >/dev/null 2>&1 && [ -f "$LOCAL_CRYPTOSHRED" ]; then
  LOCAL_CRYPT_BLOB=$(git hash-object "$LOCAL_CRYPTOSHRED" 2>/dev/null || true)
fi

if [ -n "$REMOTE_CRYPT_SHA" ] && [ -n "$LOCAL_CRYPT_BLOB" ] && [ "$REMOTE_CRYPT_SHA" = "$LOCAL_CRYPT_BLOB" ]; then
  echo -e "${GREEN}[+] Local CryptoShred.sh is up to date (git blob sha match).${NC}"
else
  echo -e "${YELLOW}[*] Remote CryptoShred.sh differs or verification unavailable; downloading for validation...${NC}"
  TMP_REMOTE_CRYPT="$(mktemp)" || { echo -e "${RED}[!] Failed to create temp file.${NC}"; exit 1; }

  if ! curl "${CURL_OPTS[@]}" -o "$TMP_REMOTE_CRYPT" "$CRYPTOSHRED_RAW_URL"; then
    echo -e "${RED}[!] Failed to download CryptoShred.sh from $CRYPTOSHRED_RAW_URL. Continuing with local copy.${NC}"
    rm -f "$TMP_REMOTE_CRYPT"
  else
    # Basic sanity: must start with a shell shebang
    if ! sed -n '1p' "$TMP_REMOTE_CRYPT" | grep -qE '^#!.*/bin/(ba)?sh'; then
      echo -e "${RED}[!] Downloaded CryptoShred.sh missing valid shebang. Rejecting.${NC}"
      rm -f "$TMP_REMOTE_CRYPT"
    else
      # Prefer blob SHA verification via GitHub API (stronger, same algorithm as git)
      if [ -n "$REMOTE_CRYPT_SHA" ] && command -v git >/dev/null 2>&1; then
        DL_BLOB="$(git hash-object "$TMP_REMOTE_CRYPT" 2>/dev/null || true)"
        if [ -n "$DL_BLOB" ] && [ "$DL_BLOB" = "$REMOTE_CRYPT_SHA" ]; then
          echo -e "${GREEN}[+] Download validated against GitHub API blob SHA.${NC}"
          # Don't install into the host system. Put validated script into the build workspace
          # so it will be embedded into the ISO only.
          mkdir -p "$(dirname "$LOCAL_CRYPTOSHRED")"
          cp -- "$TMP_REMOTE_CRYPT" "$LOCAL_CRYPTOSHRED" || { echo -e "${RED}[!] Copy failed to $LOCAL_CRYPTOSHRED.${NC}"; rm -f "$TMP_REMOTE_CRYPT"; exit 1; }
          chmod 0755 "$LOCAL_CRYPTOSHRED" || true
          sync "$LOCAL_CRYPTOSHRED" || true
          echo -e "${GREEN}[+] CryptoShred.sh downloaded to $LOCAL_CRYPTOSHRED (will be embedded into ISO).${NC}"
          rm -f "$TMP_REMOTE_CRYPT"
        else
          echo -e "${RED}[!] Download blob SHA mismatch (expected ${REMOTE_CRYPT_SHA:-<none>}). Rejecting.${NC}"
          echo "    Downloaded: ${DL_BLOB:-<missing>}"
          rm -f "$TMP_REMOTE_CRYPT"
        fi
      else
        # Fallback: sha256 compare (less ideal but useful when git/API not available)
        REMOTE_HASH=$(sha256sum "$TMP_REMOTE_CRYPT" | cut -d' ' -f1)
        LOCAL_HASH=$([ -f "$LOCAL_CRYPTOSHRED" ] && sha256sum "$LOCAL_CRYPTOSHRED" | cut -d' ' -f1 || echo "")
        if [ -z "$REMOTE_HASH" ]; then
          echo -e "${RED}[!] Could not compute remote sha256. Rejecting download.${NC}"
          rm -f "$TMP_REMOTE_CRYPT"
        elif [ -z "$LOCAL_HASH" ] || [ "$LOCAL_HASH" != "$REMOTE_HASH" ]; then
          echo -e "${YELLOW}[*] sha256 differs or local missing; downloading CryptoShred.sh for workspace...${NC}"
          # Don't install into the host system. Put validated script into the build workspace
          # so it will be embedded into the ISO only.
          mkdir -p "$(dirname "$LOCAL_CRYPTOSHRED")"
          cp -- "$TMP_REMOTE_CRYPT" "$LOCAL_CRYPTOSHRED" || { echo -e "${RED}[!] Copy failed to $LOCAL_CRYPTOSHRED.${NC}"; rm -f "$TMP_REMOTE_CRYPT"; exit 1; }
          chmod 0755 "$LOCAL_CRYPTOSHRED" || true
          sync "$LOCAL_CRYPTOSHRED" || true
          echo -e "${GREEN}[+] CryptoShred.sh downloaded to $LOCAL_CRYPTOSHRED (will be embedded into ISO).${NC}"
          rm -f "$TMP_REMOTE_CRYPT"
        else
          echo -e "${GREEN}[+] Downloaded CryptoShred.sh matches local sha256; no update needed.${NC}"
          rm -f "$TMP_REMOTE_CRYPT"
        fi
      fi
    fi
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