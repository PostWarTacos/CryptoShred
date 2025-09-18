#!/bin/bash

# List local drives (excluding loop, CD-ROM, and removable devices)
echo "Available local drives:"
lsblk -d -o NAME,SIZE,MODEL,TYPE | grep -E 'disk'

read -p "Enter the device to encrypt (e.g., sda): " DEV

# Confirm device exists and is a local disk
if ! lsblk -d -o NAME,TYPE | grep -E "^$DEV\s+disk" > /dev/null; then
  echo "Device /dev/$DEV is not a valid local disk."
  exit 1
fi

echo "WARNING: This will irreversibly destroy ALL data on /dev/$DEV!"
read -p "Type 'YES' to continue: " CONFIRM
if [[ "$CONFIRM" != "YES" ]]; then
  echo "Aborted."
  exit 1
fi

# Overwrite the entire drive with random data to destroy all old data
echo "Overwriting /dev/$DEV with random data. This may take a long time..."
sudo dd if=/dev/urandom of=/dev/$DEV bs=10M status=progress

# Create a new LUKS2 container
echo "Creating LUKS2 container on /dev/$DEV..."
sudo cryptsetup luksFormat /dev/$DEV --type luks2

# Open the encrypted container
sudo cryptsetup open /dev/$DEV encrypted_drive

# Create a new filesystem inside the encrypted container
sudo mkfs.ext4 /dev/mapper/encrypted_drive

echo "Drive /dev/$DEV is now fully encrypted and ready for use."
echo "You can mount it with:"
echo "  sudo cryptsetup open /dev/$DEV encrypted_drive"
echo "  sudo mount /dev/mapper/encrypted_drive /mnt"