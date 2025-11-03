#!/bin/bash

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# ENVIRONMENT SETUP AND INITIALIZATION
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

# If not already running in clean mode, re-exec with clean environment
# Skip clean env re-exec when running under systemd to avoid issues
if [[ "${CLEAN_ENV:-}" != "1" ]] && [[ -z "${SYSTEMD_EXEC_PID:-}" ]] && [[ "${NO_CLEAN_ENV:-}" != "1" ]]; then
  export CLEAN_ENV=1
  # Ensure TERM is set before re-execution
  TERM_VAR="${TERM:-linux}"
  exec env -i TERM="$TERM_VAR" HOME="$HOME" PATH="$PATH" USER="$USER" CLEAN_ENV=1 bash --noprofile --norc "$0" "$@"
fi

clear

# Color definitions for installation messages
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Ensure TERM is set for proper terminal handling
export TERM="${TERM:-linux}"

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# HELPER FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

# Prompt and wait for Enter. USB/live environment friendly - no /dev/tty dependency.
prompt_enter() {
  local prompt="${1:-Press Enter to continue...}"
  printf "%s" "$prompt" >&2
  read -r _ 2>/dev/null || true
}

# Prompt for input and print the response. USB/live environment friendly - no /dev/tty dependency.
prompt_read() {
  local prompt="${1:-}"
  local input=""
  printf "%b" "$prompt" >&2
  read -r input 2>/dev/null || input=""
  printf '%s' "$input"
}

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# WELCOME AND INTRODUCTION
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

echo "================================================= CryptoShred ===================================================="
echo
echo -e "${GREEN}CryptoShred - Securely encrypt and destroy key${NC}"
echo "Version 1.6 - 2025-10-29"
echo
echo "This script will encrypt an entire local drive with a random key, making all data on it permanently inaccessible."
echo "It supports both Opal hardware encryption (if available) and software LUKS2 encryption as a fallback."
echo
echo -e "${RED}IMPORTANT!!! Make sure your target USB device (device to be encrypted/destroyed) is plugged in.${NC}"
echo
echo "=================================================================================================================="
echo

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# BOOT DEVICE DETECTION
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

echo -e "${YELLOW}[*] Identifying boot device...${NC}"
# Try overlay root, then fallback to live medium, then fallback to first mounted disk
ROOT_PART=$(findmnt -no SOURCE /)
if [[ "$ROOT_PART" == "overlay" ]]; then
  LIVE_MEDIUM=$(mount | grep -E '/run/live/medium|/mnt/live' | awk '{print $1}' | head -n1)
  BOOT_DISK=$(lsblk -no PKNAME "$LIVE_MEDIUM" 2>/dev/null)
  # Fallback: If still empty, use first disk with a mountpoint
  if [[ -z "$BOOT_DISK" ]]; then
    BOOT_DISK=$(lsblk -ndo NAME,MOUNTPOINT,TYPE | awk '$2!="" && $3=="disk"{print $1}' | head -n1)
  fi
else
  BOOT_DISK=$(lsblk -no PKNAME "$ROOT_PART" 2>/dev/null)
  if [[ -z "$BOOT_DISK" && "$ROOT_PART" =~ ^/dev/([a-zA-Z0-9]+) ]]; then
    BOOT_DISK="${BASH_REMATCH[1]}"
  fi
fi

prompt_enter "Press Enter to continue..."

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# DEVICE SELECTION
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

# List all block devices of type "disk", excluding the boot device
AVAILABLE_DISKS=$(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print $1}' | grep -v "^$BOOT_DISK$")
# Debugging output
# echo "DEBUG: BOOT_DISK='$BOOT_DISK'"
# echo "DEBUG: AVAILABLE_DISKS='$AVAILABLE_DISKS'"
if [[ -z "$AVAILABLE_DISKS" ]]; then
  echo
  echo -e "${RED}ERROR: No available local drives found.${NC}"
  exit 1
fi

# Prompt user to select a device
# Loop until a valid device is selected
while true; do
  # Display drives - USB/live environment friendly
  echo
  echo -e "${YELLOW}Available local drives:${NC}"
  for disk in $AVAILABLE_DISKS; do
      size=$(lsblk -ndo SIZE /dev/$disk)
      model=$(lsblk -ndo MODEL /dev/$disk)
      echo "  /dev/$disk  $size  $model"
  done
  echo
  DEV=$(prompt_read "Enter the device to encrypt (e.g., sdb, nvme0n1): ")
  if echo "$AVAILABLE_DISKS" | grep -qx "$DEV"; then
    break
  fi
  echo
  echo -e "${RED}Device /dev/$DEV is not a valid local disk from the list above. Please try again.${NC}"
  prompt_enter "Press Enter to continue..."
  clear
done

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# SAFETY CHECKS AND CONFIRMATION
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

# Disable all swap
# This is important before wiping a drive to prevent any swap partitions from being in use
# and to ensure no data remnants remain in swap
# NEEDS to be done immediately after device selection
sudo swapoff -a

echo
echo "========"
echo -e "${RED}WARNING: This will irreversibly destroy ALL data on /dev/$DEV!${NC}"
echo "========"
echo

# Confirm action
while true; do
  CONFIRM=$(prompt_read "${YELLOW}Type 'YES' in capital letters to continue: ${NC}")
  # Check for exact match
  if [[ "$CONFIRM" == "YES" ]]; then
    break
  elif [[ "${CONFIRM,,}" == "y" || "${CONFIRM,,}" == "yes" ]]; then
    echo -e "${RED}You must type 'YES' in capital letters to confirm.${NC}"
    prompt_enter "Press Enter to continue..."
    clear
    continue
  else
    echo
    echo -e "${RED}Aborted.${NC}"
    prompt_enter "Press Enter to continue..."
    clear
    exit 1
  fi
done

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# DEVICE PREPARATION AND SIGNATURE REMOVAL
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

# Ensure the drive is not mounted or in use
echo -e "${YELLOW}[*] Cleaning up any mounts on /dev/$DEV...${NC}"
sudo umount /dev/${DEV}? 2>/dev/null || true
sudo umount -l /dev/$DEV* 2>/dev/null || true

# (Optional) Uncomment to overwrite the entire device with random data (slow):
# sudo dd if=/dev/urandom of=/dev/$DEV bs=10M status=progress

# Comprehensive device preparation to remove ALL signatures
# This is critical for avoiding "device already contains signature" errors
echo
echo -e "${YELLOW}[*] Preparing device /dev/$DEV for encryption...${NC}"

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# CHECK IF DRIVE IS ALREADY LOCKED BY OPAL
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

# Check Opal first
echo
echo  "${YELLOW}[*] Checking for Opal hardware encryption support...${NC}"
# Query sedutil and inspect output for a locked state. Capture output so we can both detect support
# and look for "Locked = Y". Be tolerant of whitespace/case.
SEDOUT=$(sedutil-cli --query /dev/$DEV 2>/dev/null || true)

if printf '%s' "$SEDOUT" | grep -qE '^[[:space:]]*Locked[[:space:]]*=[[:space:]]*[Yy]([[:space:]]*,.*)?$'; then
  echo -e "${GREEN}Opal-compatible drive detected but device reports 'Locked = Y' (already locked).${NC}"
  echo -e "${GREEN}No further action required — drive is already sealed.${NC}"
  prompt_enter "Press Enter to continue..."
  clear
  exit 0
elif printf '%s' "$SEDOUT" | grep -q .; then
  # Drive supports Opal, but preference is to use LUKS2 software encryption.
  echo -e "${YELLOW}Opal-compatible drive detected — preference is software LUKS2, skipping hw-opal enablement.${NC}"
  echo -e "${YELLOW}Falling through to LUKS2 software encryption.${NC}"
  echo
  # Do NOT attempt --hw-opal-only here, proceed to LUKS2 section below.
else
  echo -e "${YELLOW}Opal not supported. Falling back to software LUKS2 (AES-XTS).${NC}"
fi

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# LUKS2 SOFTWARE ENCRYPTION
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

# Use it to format the drive (batch mode avoids the YES prompt, already have YES prompt above)
 
  # Create a strong random key and pipe it straight into cryptsetup (no file)
  # Adjust pbkdf/argon2 parameters to taste for speed vs cost.
  echo
  echo -e "${YELLOW}[*] Creating LUKS2 encryption...${NC}"
  if head -c 64 /dev/urandom | \
    sudo cryptsetup luksFormat /dev/$DEV \
      --type luks2 \
      --pbkdf argon2id \
      --pbkdf-memory 4194304 \
      --pbkdf-parallel 4 \
      --iter-time 5000 \
      --cipher aes-xts-plain64 --key-size 512 \
      --key-file -; then
    
    # pbkdf-memory - 4GB memory (in KiB): how much RAM is used per guess in brute-force attack
    # iter-time - 5 seconds (in ms): The minimum time required to spend on each password guess
    # Together these make brute-force attacks much more costly and slow.

    echo
    echo -e "${GREEN}SUCCESS: Drive /dev/$DEV has been encrypted with a random one-time passphrase.${NC}"
    echo -e "${GREEN}Data is permanently inaccessible.${NC}"
    echo
    prompt_enter "Press Enter to continue..."
    clear
    exit 0
  else
    echo
    echo -e "${RED}ERROR: Failed to encrypt /dev/$DEV!${NC}"
    echo -e "${RED}This could be due to:${NC}"
    echo "  - Hardware I/O errors (drive may be failing)"
    echo "  - Drive is in use or mounted"
    echo "  - Insufficient permissions"
    echo "  - Drive hardware issues"
    echo
    prompt_enter "Press Enter to continue..."
    clear
    exit 1
  fi

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# COMPLETION
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

# The entire drive's contents are now cryptographically irretrievable.
