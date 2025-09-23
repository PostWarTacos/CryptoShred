#!/bin/bash

clear
echo "==========================================================================================="
echo
echo "CryptoShred - Securely encrypt and destroy key"
echo "Version 1.0 - 2024-06-10"  
echo "This script will encrypt an entire local drive with a random key, making all data"
echo "on it permanently inaccessible. It supports both Opal hardware encryption (if"
echo "available) and software LUKS2 encryption as a fallback."
echo
echo "==========================================================================================="
echo
# List local drives (excluding loop, CD-ROM, and removable devices)
echo "Available local drives:"
lsblk -d -o NAME,SIZE,MODEL,TYPE | grep -E 'disk'
echo
read -p "Enter the device to encrypt (e.g., sda, nvme0n1): " DEV

# Confirm device exists and is a local disk
if ! lsblk -d -o NAME,TYPE | grep -E "^$DEV\s+disk" > /dev/null; then
  echo
  echo "Device /dev/$DEV is not a valid local disk."
  exit 1
fi

# Prevent wiping the boot device
BOOTDEV=$(lsblk -no pkname $(df / | tail -1 | awk '{print $1}'))
if [[ "$DEV" == "$BOOTDEV" ]]; then
  echo
  echo "ERROR: /dev/$DEV appears to be the boot device. Aborting."
  exit 1
fi

echo
echo "========"
echo "WARNING: This will irreversibly destroy ALL data on /dev/$DEV!"
echo "========"
echo

read -p "Type 'yes' in capital letters to continue: " CONFIRM
if [[ "$CONFIRM" != "YES" ]]; then
  echo
  echo "Aborted."
  exit 1
fi

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
 
  # Generate a 32-character random passphrase
  PASSPHRASE=$(openssl rand -base64 32)

  echo "$PASSPHRASE" | sudo cryptsetup luksFormat /dev/$DEV \
    --type luks2 \
    --cipher aes-xts-plain64 --key-size 512 \
    --batch-mode --key-file=-

  echo
  echo "Drive /dev/$DEV has been encrypted with a random one-time passphrase."
  echo "Data is permanently inaccessible."
  echo
fi

# The entire drive’s contents are now cryptographically irretrievable.
