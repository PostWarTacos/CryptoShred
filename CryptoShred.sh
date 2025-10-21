#!/bin/bash

# If not already running in clean mode, re-exec with clean environment
# Skip clean env re-exec when running under systemd to avoid issues
if [[ "${CLEAN_ENV:-}" != "1" ]] && [[ -z "${SYSTEMD_EXEC_PID:-}" ]] && [[ "${NO_CLEAN_ENV:-}" != "1" ]]; then
  export CLEAN_ENV=1
  # Ensure TERM is set before re-execution
  TERM_VAR="${TERM:-linux}"
  exec env -i TERM="$TERM_VAR" HOME="$HOME" PATH="$PATH" USER="$USER" CLEAN_ENV=1 bash --noprofile --norc "$0" "$@"
fi

clear

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

echo "==========================================================================================="
echo
echo "CryptoShred - Securely encrypt and destroy key"
echo "Version 1.3 - 2025-10-01"  
echo "This script will encrypt an entire local drive with a random key, making all data"
echo "on it permanently inaccessible. It supports both Opal hardware encryption (if"
echo "available) and software LUKS2 encryption as a fallback."
echo
echo "==========================================================================================="
echo


echo "Identifying boot device..."
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

# List all block devices of type "disk", excluding the boot device
AVAILABLE_DISKS=$(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print $1}' | grep -v "^$BOOT_DISK$")
# Debugging output
# echo "DEBUG: BOOT_DISK='$BOOT_DISK'"
# echo "DEBUG: AVAILABLE_DISKS='$AVAILABLE_DISKS'"
if [[ -z "$AVAILABLE_DISKS" ]]; then
  echo
  echo "ERROR: No available local drives found."
  exit 1
fi

# Prompt user to select a device
# Loop until a valid device is selected
while true; do
  # Display drives - USB/live environment friendly
  echo
  echo "Available local drives:"
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
  echo "Device /dev/$DEV is not a valid local disk from the list above. Please try again."
  prompt_enter "Press Enter to continue..."
  clear
done

# Disable all swap
# This is important before wiping a drive to prevent any swap partitions from being in use
# and to ensure no data remnants remain in swap
# NEEDS to be done immediately after device selection
sudo swapoff -a

echo
echo "========"
echo "WARNING: This will irreversibly destroy ALL data on /dev/$DEV!"
echo "========"
echo

# Confirm action
while true; do
  CONFIRM=$(prompt_read "Type 'YES' in capital letters to continue: ")
  # Check for exact match
  if [[ "$CONFIRM" == "YES" ]]; then
    break
  elif [[ "${CONFIRM,,}" == "y" || "${CONFIRM,,}" == "yes" ]]; then
    prompt_enter "Press Enter to continue..."
    clear
    continue
  else
    echo
    echo "Aborted."
    prompt_enter "Press Enter to continue..."
    clear
    exit 1
  fi
done

# Ensure the drive is not mounted or in use
echo "Cleaning up any mounts on /dev/$DEV..."
sudo umount /dev/${DEV}? 2>/dev/null
sudo umount -l /dev/$DEV* 2>/dev/null
sudo wipefs -a /dev/$DEV

# (Optional) Uncomment to overwrite the entire device with random data (slow):
# sudo dd if=/dev/urandom of=/dev/$DEV bs=10M status=progress

# Quick wipe of headers and edges before encryption
# This helps prevent recovery of any plaintext remnants, 
# prevents discovery of old partitions, and ensures no old signatures 
# interfere with encryption setup (e.g., old RAID, LVM, filesystem signatures)

echo
echo "Wiping old signatures and headers on /dev/$DEV..."
echo "Overwriting first 100MB..."
sudo dd if=/dev/urandom of=/dev/$DEV bs=1M count=100 status=none 2>/dev/null
echo "Overwriting last 100MB..."
sudo dd if=/dev/urandom of=/dev/$DEV bs=1M count=100 \
  seek=$(( $(blockdev --getsz /dev/$DEV) / 2048 - 100 )) status=none 2>/dev/null
echo "Wipe first and last 100MB complete."

# Try Opal first
echo
echo  "Checking for Opal hardware encryption support..."
if cryptsetup luksFormat --hw-opal-only --test-passphrase /dev/$DEV 2>/dev/null; then
    echo "Opal-compatible drive detected. Using hardware encryption..."
    sudo cryptsetup luksFormat /dev/$DEV --hw-opal-only --batch-mode
    echo "Opal encryption enabled on /dev/$DEV."
    echo "No filesystem created, drive encrypts transparently."
else # Fallback to LUKS2
  # Use it to format the drive (batch mode avoids the YES prompt, already have YES prompt above)
  echo "Opal not supported. Falling back to software LUKS2 (AES-XTS)."
 
  # Create a strong random key and pipe it straight into cryptsetup (no file)
  # Adjust pbkdf/argon2 parameters to taste for speed vs cost.
  echo
  echo "Creating LUKS2 encryption..."
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
    echo "SUCCESS: Drive /dev/$DEV has been encrypted with a random one-time passphrase."
    echo "Data is permanently inaccessible."
    echo
    prompt_enter "Press Enter to continue..."
    clear
    exit 0
  else
    echo
    echo "ERROR: Failed to encrypt /dev/$DEV!"
    echo "This could be due to:"
    echo "  - Hardware I/O errors (drive may be failing)"
    echo "  - Drive is in use or mounted"
    echo "  - Insufficient permissions"
    echo "  - Drive hardware issues"
    echo
    prompt_enter "Press Enter to continue..."
    clear
    exit 1
  fi
fi

# The entire drive’s contents are now cryptographically irretrievable.
