#!/bin/bash

clear
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

# Identify the boot device to prevent accidental selection
BOOTDEV=$(findmnt -no SOURCE / | xargs -I{} lsblk -no PKNAME {})
# List local drives (excluding loop, CD-ROM, and removable devices)
echo "Available local drives:"
lsblk -d -o NAME,SIZE,MODEL,TYPE,MOUNTPOINT | grep -E 'disk' | grep -vi $BOOTDEV
echo
while true; do
  # Prompt for device to encrypt
  read -p "Enter the device to encrypt (e.g., sdb, nvme0n1): " DEV
  # Check if entered device is in the lsblk output and is a disk
  if lsblk -d -o NAME,TYPE | grep -E "^$DEV\s+disk" > /dev/null; then
    # Prevent wiping the boot device
    if [[ "$DEV" == "$BOOTDEV" ]]; then
      echo
      echo "ERROR: /dev/$DEV appears to be the boot device. Please choose another device."
      read -p "Press Enter to continue..."
      clear
      continue
    fi
    break
  fi
  echo
  echo "Device /dev/$DEV is not a valid local disk from the list above. Please try again."
  read -p "Press Enter to continue..."
  clear
done

# Prevent wiping the boot device
#BOOTDEV=$(findmnt -no SOURCE / | xargs -I{} lsblk -no PKNAME {})
#if [[ "$DEV" == "$BOOTDEV" ]]; then
#  echo
#  echo "ERROR: /dev/$DEV appears to be the boot device. Aborting."
#  exit 1
#fi

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
  read -p "Type 'YES' in capital letters to continue: " CONFIRM
  # Check for exact match
  if [[ "$CONFIRM" == "YES" ]]; then
    break
  # elif [[ "$CONFIRM" == "yes" || "$CONFIRM" == "y" ]]; then continue
  elif [[ "${CONFIRM,,}" == "y" || "${CONFIRM,,}" == "yes" ]]; then
    read -p "Press Enter to continue..."
    clear
    continue
  else
    echo
    echo "Aborted."
    read -p "Press Enter to continue..."
    clear
    exit 1
  fi
done

# Ensure the drive is not mounted or in use
echo "Cleaning up any mounts on /dev/$DEV..."
sudo umount /dev/${DEV}? 2>/dev/null
sudo umount -l /dev/$DEV* 2>/dev/null
sudo wipefs -a /dev/$DEV

# (Optional) Full overwrite with random data
# If you want to ensure no data remnants remain, uncomment this section.
# Note: This can take hours on large drives.
# If you want to skip this, the quick header/edge wipe (next section below) is usually sufficient.
# echo "Overwriting /dev/$DEV with random data. This may take a long time..."
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
  head -c 64 /dev/urandom | \
    sudo cryptsetup luksFormat /dev/$DEV \
      --type luks2 \
      --pbkdf argon2id \
      --pbkdf-memory 4194304 \
      --pbkdf-parallel 4 \
      --iter-time 5000 \
      --cipher aes-xts-plain64 --key-size 512 \
      --key-file -
  
  # pbkdf-memory - 4GB memory (in KiB): how much RAM is used per guess in brute-force attack
  # iter-time - 5 seconds (in ms): The minimum time required to spend on each password guess
  # Together these make brute-force attacks much more costly and slow.

  echo
  echo "Drive /dev/$DEV has been encrypted with a random one-time passphrase."
  echo "Data is permanently inaccessible."
  echo "No filesystem created, drive encrypts transparently."
  echo
  read -p "Press Enter to continue..."
  clear
  # Will return 0 and continue to the end of the script
  # Which will restart the script to allow another device to be selected
  exit 0
fi

# The entire drive’s contents are now cryptographically irretrievable.
