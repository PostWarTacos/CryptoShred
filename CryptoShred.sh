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

# Debugging output
# Uncomment the following lines to enable persistent logging
# This will create a log file in /var/log/cryptoshred with timestamped entries
# This is useful for debugging and inspecting runs after the system has booted

# Persistent logging so we can inspect live runs after first boot
# LOGDIR="/var/log/cryptoshred"
# mkdir -p "$LOGDIR"
# LOGFILE="$LOGDIR/cryptoshred-$(date +%Y%m%d-%H%M%S).log"
# Redirect stdout/stderr to logfile while still echoing to console when possible
# exec > >(tee -a "$LOGFILE") 2>&1

# echo
# echo "[LOGFILE] $LOGFILE"
# echo "[INFO] Invoked by: $(whoami)"
# echo "[INFO] Shell: $SHELL"
# echo

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
  printf "%s" "$prompt" >&2
  read -r input 2>/dev/null || input=""
  printf '%s' "$input"
}

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# WELCOME AND INTRODUCTION
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

echo "================================================= CryptoShred ===================================================="
echo
echo "${GREEN}CryptoShred - Securely encrypt and destroy key${NC}"
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

echo "${YELLOW}[*] Identifying boot device...${NC}"
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

# Debugging output
# echo "DEBUG: ROOT_PART='$ROOT_PART'"
# echo "DEBUG: LIVE_MEDIUM='$LIVE_MEDIUM'"
# echo "DEBUG: BOOT_DISK='$BOOT_DISK'"

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
  echo "${RED}ERROR: No available local drives found.${NC}"
  exit 1
fi

# Prompt user to select a device
# Loop until a valid device is selected
while true; do
  # Display drives - USB/live environment friendly
  echo
  echo "${YELLOW}Available local drives:${NC}"
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
  echo "${RED}Device /dev/$DEV is not a valid local disk from the list above. Please try again.${NC}"
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
echo "${RED}WARNING: This will irreversibly destroy ALL data on /dev/$DEV!${NC}"
echo "========"
echo

# Confirm action
while true; do
  CONFIRM=$(prompt_read "${YELLOW}Type 'YES' in capital letters to continue: ${NC}")
  # Check for exact match
  if [[ "$CONFIRM" == "YES" ]]; then
    break
  elif [[ "${CONFIRM,,}" == "y" || "${CONFIRM,,}" == "yes" ]]; then
    echo "${RED}You must type 'YES' in capital letters to confirm.${NC}"
    prompt_enter "Press Enter to continue..."
    clear
    continue
  else
    echo
    echo "${RED}Aborted.${NC}"
    prompt_enter "Press Enter to continue..."
    clear
    exit 1
  fi
done

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# DEVICE PREPARATION AND SIGNATURE REMOVAL
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

# Ensure the drive is not mounted or in use
echo "${YELLOW}[*] Cleaning up any mounts on /dev/$DEV...${NC}"
sudo umount /dev/${DEV}? 2>/dev/null || true
sudo umount -l /dev/$DEV* 2>/dev/null || true

# (Optional) Uncomment to overwrite the entire device with random data (slow):
# sudo dd if=/dev/urandom of=/dev/$DEV bs=10M status=progress

# Comprehensive device preparation to remove ALL signatures
# This is critical for avoiding "device already contains signature" errors
echo
echo "${YELLOW}[*] Preparing device /dev/$DEV for encryption...${NC}"

# Get device size once and store it
DEVICE_SIZE=$(sudo blockdev --getsz /dev/$DEV)
echo "${YELLOW}Device size: $DEVICE_SIZE sectors ($(( DEVICE_SIZE * 512 / 1024 / 1024 / 1024 )) GB)${NC}"

# # Check if signatures exist and determine if full cleaning is needed
# echo "Checking for existing signatures..."
# SIGNATURES_FOUND=false
# if sudo wipefs /dev/$DEV 2>/dev/null | grep -q .; then
#   SIGNATURES_FOUND=true
#   echo "Signatures detected. Starting comprehensive 7-step cleaning process..."
#   echo
  
#   # Step 1: Multiple passes of signature removal with verification
#   # echo "Pass 1: Initial signature removal..."
#   # sudo wipefs -af /dev/$DEV 2>/dev/null || true

#   # Step 2: Aggressive zero-fill of critical areas
#   # echo "Pass 2: Zeroing critical partition areas..."
#   # # Zero first 10MB (covers MBR, GPT primary, and any extended headers)
#   # sudo dd if=/dev/zero of=/dev/$DEV bs=1M count=10 status=none 2>/dev/null || true
#   # # Zero last 10MB (covers GPT backup and any trailing metadata)
#   # LAST_10MB_OFFSET=$(( (DEVICE_SIZE * 512 - 10485760) / 512 ))
#   # if [ $LAST_10MB_OFFSET -gt 0 ]; then
#   #   sudo dd if=/dev/zero of=/dev/$DEV bs=512 count=20480 seek=$LAST_10MB_OFFSET status=none 2>/dev/null || true
#   # fi

#   # Step 3: Force immediate kernel rescan
#   # echo "Pass 3: Forcing kernel device table refresh..."
#   # sudo blockdev --rereadpt /dev/$DEV 2>/dev/null || true
#   # sudo partprobe /dev/$DEV 2>/dev/null || true
#   # sudo udevadm settle 2>/dev/null || true
#   # sleep 2

#   # Step 4: Verify and repeat signature removal
#   # echo "Pass 4: Verification and cleanup..."
#   # sudo wipefs -af /dev/$DEV 2>/dev/null || true

#   # Step 5: Overwrite with random data to prevent any recovery
#   # echo "Pass 5: Random data overwrite (first/last 100MB)..."
#   # sudo dd if=/dev/urandom of=/dev/$DEV bs=1M count=100 status=none 2>/dev/null || true
#   # sudo dd if=/dev/urandom of=/dev/$DEV bs=1M count=100 \
#   #   seek=$(( DEVICE_SIZE / 2048 - 100 )) status=none 2>/dev/null || true

#   # Step 6: Final comprehensive cleanup and verification
#   # echo "Pass 6: Final cleanup and sync..."
#   # sudo wipefs -af /dev/$DEV 2>/dev/null || true
#   # sudo blockdev --rereadpt /dev/$DEV 2>/dev/null || true
#   # sudo partprobe /dev/$DEV 2>/dev/null || true
#   # sudo udevadm settle 2>/dev/null || true
#   # sync
#   # sleep 3

#   # Step 7: Verify no signatures remain
#   # echo "Verifying signature removal..."
#   # SIGNATURES_STILL_PRESENT=false
#   # if sudo wipefs /dev/$DEV 2>/dev/null | grep -q .; then
#   #   SIGNATURES_STILL_PRESENT=true
#   #   echo "WARNING: Some signatures may still be present:"
#   #   sudo wipefs /dev/$DEV 2>/dev/null || true
#   #   echo "Attempting force removal..."
#   #   sudo dd if=/dev/zero of=/dev/$DEV bs=1M count=50 status=none 2>/dev/null || true
#   #   sudo wipefs -af /dev/$DEV 2>/dev/null || true
#   #   sync
#   #   sleep 2
#   #   
#   #   # Re-check after step 7's last-ditch efforts
#   #   echo "Re-checking signatures after step 7 cleanup..."
#   #   if sudo wipefs /dev/$DEV 2>/dev/null | grep -q .; then
#   #     echo "Signatures still persist after step 7."
#   #     SIGNATURES_STILL_PRESENT=true
#   #   else
#   #     echo "Step 7 cleanup successful - all signatures removed."
#   #     SIGNATURES_STILL_PRESENT=false
#   #   fi
#   # else
#   #   echo "All signatures successfully removed."
#   # fi

#   echo "7-step cleaning process skipped (commented out)."
#   # Set variables for compatibility with later sections
#   SIGNATURES_STILL_PRESENT=false

#   echo "Device preparation complete."
# else
#   echo "No signatures detected. Device appears clean."
#   echo
# fi

# # ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# # FINAL CRYPTSETUP-SPECIFIC SIGNATURE REMOVAL
# # ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

# # Ultra-aggressive final step: Use cryptsetup's own signature detection and removal
# # This handles signatures that wipefs might miss but cryptsetup can see
# # Only run this if we detected signatures initially AND they still persist after 7-step process
# if [ "$SIGNATURES_FOUND" = true ] && [ "$SIGNATURES_STILL_PRESENT" = true ]; then
#   echo "Signatures survived 7-step process. Deploying nuclear option..."

#   # Force remove any signatures that cryptsetup specifically detects
#   echo "Attempting cryptsetup signature removal..."
#   sudo cryptsetup erase /dev/$DEV 2>/dev/null || true

#   # Nuclear option: Overwrite first and last 1GB with zeros (handles any deep metadata)
#   echo "Nuclear option: Zeroing first and last 1GB..."
#   sudo dd if=/dev/zero of=/dev/$DEV bs=1M count=1024 status=none 2>/dev/null || true
#   if [ $((DEVICE_SIZE * 512)) -gt 2147483648 ]; then  # Only if device > 2GB
#     LAST_1GB_OFFSET=$(( (DEVICE_SIZE * 512 - 1073741824) / 512 ))
#     sudo dd if=/dev/zero of=/dev/$DEV bs=512 count=2097152 seek=$LAST_1GB_OFFSET status=none 2>/dev/null || true
#   fi

#   # Force kernel to completely forget about this device and rescan
#   echo "Forcing complete device reset..."
#   echo 1 | sudo tee /sys/block/${DEV}/device/delete 2>/dev/null || true
#   echo "- - -" | sudo tee /sys/class/scsi_host/host*/scan 2>/dev/null || true
#   sleep 5
#   sudo partprobe /dev/$DEV 2>/dev/null || true
#   sudo udevadm settle 2>/dev/null || true
#   sync
#   sleep 3

#   echo "Ultra-aggressive cleaning complete."
# elif [ "$SIGNATURES_FOUND" = true ]; then
#   echo "7-step process successfully removed all signatures. Nuclear option not needed."
# else
#   echo "Device was already clean - skipping ultra-aggressive cleaning."
# fi
# echo

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
  echo "${GREEN}Opal-compatible drive detected but device reports 'Locked = Y' (already locked).${NC}"
  echo "${GREEN}No further action required — drive is already sealed.${NC}"
  prompt_enter "Press Enter to continue..."
  clear
  exit 0
elif printf '%s' "$SEDOUT" | grep -q .; then
  # Drive supports Opal, but preference is to use LUKS2 software encryption.
  echo "${YELLOW}Opal-compatible drive detected — preference is software LUKS2, skipping hw-opal enablement.${NC}"
  echo "${YELLOW}Falling through to LUKS2 software encryption.${NC}"
  echo
  # Do NOT attempt --hw-opal-only here, proceed to LUKS2 section below.
else
  echo "${YELLOW}Opal not supported. Falling back to software LUKS2 (AES-XTS).${NC}"
fi

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# LUKS2 SOFTWARE ENCRYPTION
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

# Use it to format the drive (batch mode avoids the YES prompt, already have YES prompt above)
 
  # Create a strong random key and pipe it straight into cryptsetup (no file)
  # Adjust pbkdf/argon2 parameters to taste for speed vs cost.
  echo
  echo "${YELLOW}[*] Creating LUKS2 encryption...${NC}"
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
    echo "${GREEN}SUCCESS: Drive /dev/$DEV has been encrypted with a random one-time passphrase.${NC}"
    echo "${GREEN}Data is permanently inaccessible.${NC}"
    echo
    prompt_enter "Press Enter to continue..."
    clear
    exit 0
  else
    echo
    echo "${RED}ERROR: Failed to encrypt /dev/$DEV!${NC}"
    echo "${RED}This could be due to:${NC}"
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
