#!/bin/bash

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# UNIVERSAL BUILD ENVIRONMENT CLEANUP SCRIPT
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

# This script cleans up build environments left by various ISO/Live system build scripts
# including BuildCryptoShred.sh, BuildDebianLive.sh, and similar scripts.
# It handles mount cleanup, process termination, and workspace removal to allow
# running build scripts again without requiring a reboot.

set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# INITIAL SETUP AND CHECKS
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

echo "═══════════════════════════════════════════════════════════════════════════════════════"
echo "Universal Build Environment Cleanup Script"
echo "Version 2.0 - 2025-10-27"
echo
echo "This script will clean up build environments left by ISO/Live system build scripts"
echo "including BuildCryptoShred.sh, BuildDebianLive.sh, and similar build processes."
echo "It allows running build scripts again without requiring a reboot."
echo "═══════════════════════════════════════════════════════════════════════════════════════"
echo

# Check for root permissions
if [ "$EUID" -ne 0 ]; then
  echo "[!] Please run this script as root (sudo)."
  echo "    Example: sudo bash CleanupCryptoShred.sh"
  exit 1
fi

# Get the real user's home directory
if [ -n "${SUDO_USER:-}" ]; then
  REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
  REAL_HOME="$HOME"
fi

# Define common build directory patterns
COMMON_BUILD_DIRS=(
  "$REAL_HOME/live-iso-work"
  "$REAL_HOME/debian-live-work"
  "$REAL_HOME/iso-build"
  "$REAL_HOME/build-workspace"
  "$REAL_HOME/live-build"
  "/tmp/live-iso-work"
  "/tmp/debian-live-work"
  "/tmp/iso-build"
  "/var/tmp/live-iso-work"
)

# Auto-detect additional build directories
echo "[*] Auto-detecting build directories..."
DETECTED_DIRS=()

# Look for directories with common build patterns
for pattern in "*live*work*" "*iso*work*" "*build*work*" "*debian*live*" "*live*build*"; do
  for location in "$REAL_HOME" "/tmp" "/var/tmp"; do
    if [ -d "$location" ]; then
      while IFS= read -r -d '' dir; do
        if [ -d "$dir" ] && [[ "$dir" =~ (edit|iso|squashfs|chroot) ]]; then
          DETECTED_DIRS+=("$dir")
        fi
      done < <(find "$location" -maxdepth 1 -type d -name "$pattern" -print0 2>/dev/null || true)
    fi
  done
done

# Look for directories containing typical build artifacts
for location in "$REAL_HOME" "/tmp" "/var/tmp"; do
  if [ -d "$location" ]; then
    while IFS= read -r -d '' dir; do
      if [ -d "$dir/edit" ] || [ -d "$dir/iso" ] || [ -f "$dir/debian.iso" ] || [ -f "$dir"/*.iso ]; then
        DETECTED_DIRS+=("$dir")
      fi
    done < <(find "$location" -maxdepth 2 -type d \( -name "edit" -o -name "iso" \) -print0 2>/dev/null | sed 's|/[^/]*$||' | sort -u -z || true)
  fi
done

# Combine and deduplicate directories
ALL_WORK_DIRS=()
for dir in "${COMMON_BUILD_DIRS[@]}" "${DETECTED_DIRS[@]}"; do
  if [ -d "$dir" ] && [[ ! " ${ALL_WORK_DIRS[*]} " =~ " $dir " ]]; then
    ALL_WORK_DIRS+=("$dir")
  fi
done

echo "[INFO] Real user home: $REAL_HOME"
if [ ${#ALL_WORK_DIRS[@]} -gt 0 ]; then
  echo "[INFO] Found build directories:"
  for dir in "${ALL_WORK_DIRS[@]}"; do
    echo "       - $dir"
  done
else
  echo "[INFO] No build directories found"
fi
echo

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# PROCESS CLEANUP
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

echo "[*] Checking for processes using build directories..."

# Function to clean up processes for a directory
cleanup_processes_for_dir() {
  local workdir="$1"
  local dir_name=$(basename "$workdir")
  
  if [ ! -d "$workdir" ]; then
    return 0
  fi
  
  # Use fuser to find processes using the directory
  PROCESSES=$(fuser -v "$workdir" 2>/dev/null | awk 'NR>1 {print $2}' | sort -u || true)
  
  if [ -n "$PROCESSES" ] && [ "$PROCESSES" != "" ]; then
    echo "[*] Found processes using $dir_name ($workdir):"
    fuser -v "$workdir" 2>/dev/null || true
    echo
    echo "[*] Terminating processes for $dir_name..."
    
    # First try graceful termination
    for pid in $PROCESSES; do
      if [ -n "$pid" ] && [ "$pid" -gt 1 ]; then
        echo "    Sending TERM signal to PID $pid..."
        kill -TERM "$pid" 2>/dev/null || true
      fi
    done
    
    # Wait a moment for graceful shutdown
    sleep 3
    
    # Force kill any remaining processes
    REMAINING=$(fuser -v "$workdir" 2>/dev/null | awk 'NR>1 {print $2}' | sort -u || true)
    if [ -n "$REMAINING" ] && [ "$REMAINING" != "" ]; then
      echo "[*] Force killing remaining processes for $dir_name..."
      for pid in $REMAINING; do
        if [ -n "$pid" ] && [ "$pid" -gt 1 ]; then
          echo "    Sending KILL signal to PID $pid..."
          kill -KILL "$pid" 2>/dev/null || true
        fi
      done
      sleep 2
    fi
  else
    echo "[+] No processes found using $dir_name"
  fi
}

# Clean up processes for all detected directories
if [ ${#ALL_WORK_DIRS[@]} -gt 0 ]; then
  for workdir in "${ALL_WORK_DIRS[@]}"; do
    cleanup_processes_for_dir "$workdir"
  done
else
  echo "[+] No build directories to check for processes"
fi

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# MOUNT CLEANUP
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

echo
echo "[*] Cleaning up mount points..."

# Function to safely unmount with multiple attempts
safe_unmount() {
  local mount_point="$1"
  local description="$2"
  
  if mountpoint -q "$mount_point" 2>/dev/null; then
    echo "    Unmounting $description ($mount_point)..."
    
    # Try lazy unmount first (most reliable for stuck mounts)
    if umount -l "$mount_point" 2>/dev/null; then
      echo "    ✓ Successfully unmounted $description (lazy)"
      return 0
    fi
    
    # Try force unmount
    if umount -f "$mount_point" 2>/dev/null; then
      echo "    ✓ Successfully unmounted $description (force)"
      return 0
    fi
    
    # Try regular unmount
    if umount "$mount_point" 2>/dev/null; then
      echo "    ✓ Successfully unmounted $description (regular)"
      return 0
    fi
    
    # If all else fails, report the issue but continue
    echo "    ⚠ Failed to unmount $description - may need manual intervention"
    return 1
  else
    echo "    ✓ $description not mounted"
    return 0
  fi
}

# Function to clean up mounts for a specific build directory
cleanup_mounts_for_dir() {
  local workdir="$1"
  local dir_name=$(basename "$workdir")
  
  if [ ! -d "$workdir" ]; then
    echo "[+] $dir_name directory does not exist, skipping mount cleanup"
    return 0
  fi
  
  # Check for common chroot subdirectories
  local chroot_dirs=("$workdir/edit" "$workdir/chroot" "$workdir/rootfs" "$workdir/filesystem")
  local found_chroot=""
  
  for chroot_dir in "${chroot_dirs[@]}"; do
    if [ -d "$chroot_dir" ]; then
      found_chroot="$chroot_dir"
      break
    fi
  done
  
  if [ -n "$found_chroot" ]; then
    echo "[*] Unmounting chroot filesystems in $dir_name..."
    
    # Find all mount points under the chroot directory and unmount them
    # Get them in reverse order (deepest first)
    MOUNT_POINTS=$(mount | grep "$found_chroot" | awk '{print $3}' | sort -r || true)
    
    if [ -n "$MOUNT_POINTS" ]; then
      echo "[*] Found mounted filesystems in $dir_name:"
      mount | grep "$found_chroot" || true
      echo
      
      for mount_point in $MOUNT_POINTS; do
        case "$mount_point" in
          */dev/pts)
            safe_unmount "$mount_point" "devpts"
            ;;
          */dev)
            safe_unmount "$mount_point" "/dev bind mount"
            ;;
          */run)
            safe_unmount "$mount_point" "/run bind mount"
            ;;
          */proc)
            safe_unmount "$mount_point" "/proc mount"
            ;;
          */sys)
            safe_unmount "$mount_point" "/sys mount"
            ;;
          */tmp)
            safe_unmount "$mount_point" "/tmp tmpfs"
            ;;
          *)
            safe_unmount "$mount_point" "unknown mount"
            ;;
        esac
      done
    else
      echo "[+] No mounted filesystems found in $dir_name"
    fi
  else
    echo "[+] No chroot directory found in $dir_name, skipping chroot mount cleanup"
  fi
  
  # Double-check with a more aggressive approach for any remaining mounts
  echo "[*] Performing final mount cleanup for $dir_name..."
  
  # Try to unmount any remaining mounts under this workdir
  REMAINING_MOUNTS=$(mount | grep "$workdir" | awk '{print $3}' | sort -r || true)
  if [ -n "$REMAINING_MOUNTS" ]; then
    echo "[*] Found remaining mounts in $dir_name, attempting cleanup..."
    for mount_point in $REMAINING_MOUNTS; do
      echo "    Force unmounting $mount_point..."
      umount -lf "$mount_point" 2>/dev/null || true
    done
  fi
}

# Clean up mounts for all detected directories
if [ ${#ALL_WORK_DIRS[@]} -gt 0 ]; then
  for workdir in "${ALL_WORK_DIRS[@]}"; do
    cleanup_mounts_for_dir "$workdir"
  done
else
  echo "[+] No build directories to clean up mounts for"
fi

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# LOOP DEVICE CLEANUP
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

echo
echo "[*] Cleaning up loop devices..."

# Function to find loop devices associated with a directory
find_loop_devices_for_dir() {
  local workdir="$1"
  losetup -l 2>/dev/null | grep "$workdir" | awk '{print $1}' || true
}

# Find and detach any loop devices that might be associated with build workspaces
ALL_LOOP_DEVICES=()
if [ ${#ALL_WORK_DIRS[@]} -gt 0 ]; then
  for workdir in "${ALL_WORK_DIRS[@]}"; do
    LOOP_DEVICES=$(find_loop_devices_for_dir "$workdir")
    if [ -n "$LOOP_DEVICES" ]; then
      while IFS= read -r loop_dev; do
        if [ -n "$loop_dev" ] && [[ ! " ${ALL_LOOP_DEVICES[*]} " =~ " $loop_dev " ]]; then
          ALL_LOOP_DEVICES+=("$loop_dev")
        fi
      done <<< "$LOOP_DEVICES"
    fi
  done
fi

if [ ${#ALL_LOOP_DEVICES[@]} -gt 0 ]; then
  echo "[*] Found loop devices associated with build workspaces:"
  for loop_dev in "${ALL_LOOP_DEVICES[@]}"; do
    echo "       $loop_dev"
  done
  echo
  
  for loop_dev in "${ALL_LOOP_DEVICES[@]}"; do
    echo "    Detaching $loop_dev..."
    losetup -d "$loop_dev" 2>/dev/null || true
  done
else
  echo "[+] No loop devices found associated with build workspaces"
fi

# Also check for any orphaned loop devices from ISO files
echo "[*] Checking for orphaned loop devices..."
ORPHANED_LOOPS=$(losetup -l 2>/dev/null | grep -E "\.(iso|img)$" | awk '{print $1}' || true)

if [ -n "$ORPHANED_LOOPS" ]; then
  echo "[*] Found potentially orphaned loop devices:"
  losetup -l | grep -E "\.(iso|img)$" || true
  echo
  read -p "Detach these loop devices? (y/N): " DETACH_ORPHANED
  
  if [[ "$DETACH_ORPHANED" =~ ^[Yy]$ ]]; then
    while IFS= read -r loop_dev; do
      if [ -n "$loop_dev" ]; then
        echo "    Detaching $loop_dev..."
        losetup -d "$loop_dev" 2>/dev/null || true
      fi
    done <<< "$ORPHANED_LOOPS"
  else
    echo "    Skipping orphaned loop device cleanup"
  fi
else
  echo "[+] No orphaned loop devices found"
fi

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# DIRECTORY CLEANUP
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

echo
echo "[*] Removing build directories..."

# Function to safely remove a directory
safe_remove_directory() {
  local workdir="$1"
  local dir_name=$(basename "$workdir")
  
  if [ -d "$workdir" ]; then
    echo "    Build directory $dir_name exists, attempting removal..."
    
    # First attempt: regular removal
    if rm -rf "$workdir" 2>/dev/null; then
      echo "    ✓ Build directory $dir_name removed successfully"
      return 0
    else
      echo "    Regular removal failed for $dir_name, trying alternative methods..."
      
      # Second attempt: change permissions and try again
      echo "    Changing permissions for $dir_name and retrying..."
      chmod -R 777 "$workdir" 2>/dev/null || true
      if rm -rf "$workdir" 2>/dev/null; then
        echo "    ✓ Build directory $dir_name removed after permission change"
        return 0
      else
        # Third attempt: Remove contents first, then directory
        echo "    Removing contents individually for $dir_name..."
        find "$workdir" -type f -delete 2>/dev/null || true
        find "$workdir" -depth -type d -exec rmdir {} \; 2>/dev/null || true
        
        if [ ! -d "$workdir" ]; then
          echo "    ✓ Build directory $dir_name removed after individual cleanup"
          return 0
        else
          echo "    ⚠ Some files/directories may remain in $workdir"
          echo "    You may need to manually remove them or reboot"
          
          # Show what's left
          echo "    Remaining items in $dir_name:"
          ls -la "$workdir" 2>/dev/null || true
          return 1
        fi
      fi
    fi
  else
    echo "    ✓ Build directory $dir_name does not exist"
    return 0
  fi
}

# Remove all detected build directories
REMOVAL_ISSUES=false
if [ ${#ALL_WORK_DIRS[@]} -gt 0 ]; then
  for workdir in "${ALL_WORK_DIRS[@]}"; do
    if ! safe_remove_directory "$workdir"; then
      REMOVAL_ISSUES=true
    fi
  done
else
  echo "[+] No build directories to remove"
fi

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# SYSTEM CLEANUP
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

echo
echo "[*] Performing system cleanup..."

# Clear any cached filesystem information
echo "    Clearing filesystem caches..."
sync
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

# Trigger udev to rescan devices
echo "    Triggering udev rescan..."
udevadm control --reload 2>/dev/null || true
udevadm trigger 2>/dev/null || true
udevadm settle 2>/dev/null || true

# Update the locate database if updatedb is available
if command -v updatedb >/dev/null 2>&1; then
  echo "    Updating locate database..."
  updatedb 2>/dev/null || true
fi

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# VERIFICATION AND COMPLETION
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

echo
echo "[*] Verification..."

# Check if cleanup was successful
CLEANUP_SUCCESS=true

# Check for remaining mounts in any of the build directories
REMAINING_MOUNTS=""
if [ ${#ALL_WORK_DIRS[@]} -gt 0 ]; then
  for workdir in "${ALL_WORK_DIRS[@]}"; do
    MOUNTS_FOR_DIR=$(mount | grep "$workdir" || true)
    if [ -n "$MOUNTS_FOR_DIR" ]; then
      REMAINING_MOUNTS="$REMAINING_MOUNTS$MOUNTS_FOR_DIR"$'\n'
    fi
  done
fi

if [ -n "$REMAINING_MOUNTS" ] && [ "$REMAINING_MOUNTS" != $'\n' ]; then
  echo "    ⚠ Warning: Some mounts may still exist:"
  echo "$REMAINING_MOUNTS"
  CLEANUP_SUCCESS=false
fi

# Check if any build directories still exist
REMAINING_DIRS=()
if [ ${#ALL_WORK_DIRS[@]} -gt 0 ]; then
  for workdir in "${ALL_WORK_DIRS[@]}"; do
    if [ -d "$workdir" ]; then
      REMAINING_DIRS+=("$workdir")
    fi
  done
fi

if [ ${#REMAINING_DIRS[@]} -gt 0 ]; then
  echo "    ⚠ Warning: Some build directories still exist:"
  for dir in "${REMAINING_DIRS[@]}"; do
    echo "       - $dir"
  done
  CLEANUP_SUCCESS=false
fi

# Check for processes still using any of the build directories
PROCESSES_REMAINING=""
if [ ${#ALL_WORK_DIRS[@]} -gt 0 ]; then
  for workdir in "${ALL_WORK_DIRS[@]}"; do
    if [ -d "$workdir" ]; then
      PROCS_FOR_DIR=$(fuser -v "$workdir" 2>/dev/null | awk 'NR>1 {print $2}' || true)
      if [ -n "$PROCS_FOR_DIR" ] && [ "$PROCS_FOR_DIR" != "" ]; then
        PROCESSES_REMAINING="$PROCESSES_REMAINING $PROCS_FOR_DIR"
      fi
    fi
  done
fi

if [ -n "$PROCESSES_REMAINING" ] && [ "$PROCESSES_REMAINING" != " " ]; then
  echo "    ⚠ Warning: Some processes may still be using build directories"
  CLEANUP_SUCCESS=false
fi

# Factor in directory removal issues
if [ "$REMOVAL_ISSUES" = true ]; then
  CLEANUP_SUCCESS=false
fi

echo
if [ "$CLEANUP_SUCCESS" = true ]; then
  echo "════════════════════════════════════════════════════════════════════════════════════════"
  echo "✓ CLEANUP COMPLETED SUCCESSFULLY"
  echo "════════════════════════════════════════════════════════════════════════════════════════"
  echo
  echo "The build environment has been cleaned up. You should now be able to run"
  echo "build scripts (BuildCryptoShred.sh, BuildDebianLive.sh, etc.) again without"
  echo "requiring a reboot."
  echo
  echo "If you still encounter issues, you may need to:"
  echo "  1. Wait a few minutes for the system to fully release resources"
  echo "  2. Run this cleanup script again"
  echo "  3. As a last resort, reboot the system"
else
  echo "════════════════════════════════════════════════════════════════════════════════════════"
  echo "⚠ CLEANUP COMPLETED WITH WARNINGS"
  echo "════════════════════════════════════════════════════════════════════════════════════════"
  echo
  echo "Some issues were encountered during cleanup. You may need to:"
  echo "  1. Run this script again"
  echo "  2. Manually address the warnings shown above"
  echo "  3. Reboot the system if problems persist"
  echo
  echo "Build scripts may still work, but you might encounter permission errors."
fi

echo
read -p "Press Enter to exit..."