#!/bin/bash

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# UNIVERSAL BUILD ENVIRONMENT CLEANUP SCRIPT
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

# This script cleans up build environments left by various ISO/Live system build scripts
# including BuildCryptoShred.sh, BuildDebianLive.sh, and similar scripts.
# It handles mount cleanup, process termination, and workspace removal to allow
# running build scripts again without requiring a reboot.

set -euo pipefail

# Color definitions for installation messages
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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
  echo -e "${RED}[!] Please run this script as root (sudo).${NC}"
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
echo -e "${YELLOW}[*] Auto-detecting build directories...${NC}"
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

echo -e "${BLUE}[INFO] Real user home: $REAL_HOME${NC}"
if [ ${#ALL_WORK_DIRS[@]} -gt 0 ]; then
  echo -e "${BLUE}Found build directories:${NC}"
  for dir in "${ALL_WORK_DIRS[@]}"; do
    echo "       - $dir"
  done
else
  echo -e "${BLUE}No build directories found${NC}"
fi
echo

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# PROCESS CLEANUP
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

echo -e "${YELLOW}[*] Checking for processes using build directories...${NC}"

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
    echo -e "${YELLOW}[*] Found processes using $dir_name ($workdir):${NC}"
    fuser -v "$workdir" 2>/dev/null || true
    echo
    echo -e "${YELLOW}[*] Terminating processes for $dir_name...${NC}"

    # First try graceful termination
    for pid in $PROCESSES; do
      if [ -n "$pid" ] && [ "$pid" -gt 1 ]; then
        echo -e "${YELLOW}    Sending TERM signal to PID $pid...${NC}"
        kill -TERM "$pid" 2>/dev/null || true
      fi
    done
    
    # Wait a moment for graceful shutdown
    sleep 3
    
    # Force kill any remaining processes
    REMAINING=$(fuser -v "$workdir" 2>/dev/null | awk 'NR>1 {print $2}' | sort -u || true)
    if [ -n "$REMAINING" ] && [ "$REMAINING" != "" ]; then
      echo -e "${YELLOW}[*] Force killing remaining processes for $dir_name...${NC}"
      for pid in $REMAINING; do
        if [ -n "$pid" ] && [ "$pid" -gt 1 ]; then
          echo -e "${YELLOW}    Sending KILL signal to PID $pid...${NC}"
          kill -KILL "$pid" 2>/dev/null || true
        fi
      done
      sleep 2
    fi
  else
    echo -e "${GREEN}[+] No processes found using $dir_name${NC}"
  fi
}

# Clean up processes for all detected directories
if [ ${#ALL_WORK_DIRS[@]} -gt 0 ]; then
  for workdir in "${ALL_WORK_DIRS[@]}"; do
    cleanup_processes_for_dir "$workdir"
  done
else
  echo -e "${GREEN}[+] No build directories to check for processes${NC}"
fi

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# MOUNT CLEANUP
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

echo
echo -e "${YELLOW}[*] Cleaning up mount points...${NC}"

# Function to safely unmount with multiple attempts
safe_unmount() {
  local mount_point="$1"
  local description="$2"
  
  if mountpoint -q "$mount_point" 2>/dev/null; then
    echo -e "${YELLOW}    Unmounting $description ($mount_point)...${NC}"

    # Try lazy unmount first (most reliable for stuck mounts)
    if umount -l "$mount_point" 2>/dev/null; then
      echo -e "${GREEN}    ✓ Successfully unmounted $description (lazy)${NC}"
      return 0
    fi
    
    # Try force unmount
    if umount -f "$mount_point" 2>/dev/null; then
      echo -e "${GREEN}    ✓ Successfully unmounted $description (force)${NC}"
      return 0
    fi
    
    # Try regular unmount
    if umount "$mount_point" 2>/dev/null; then
      echo -e "${GREEN}    ✓ Successfully unmounted $description (regular)${NC}"
      return 0
    fi
    
    # If all else fails, report the issue but continue
    echo -e "${YELLOW}    ⚠ Failed to unmount $description - may need manual intervention${NC}"
    return 1
  else
    echo -e "${GREEN}    ✓ $description not mounted${NC}"
    return 0
  fi
}

# Function to clean up mounts for a specific build directory
cleanup_mounts_for_dir() {
  local workdir="$1"
  local dir_name=$(basename "$workdir")
  
  if [ ! -d "$workdir" ]; then
    echo -e "${GREEN}[+] $dir_name directory does not exist, skipping mount cleanup${NC}"
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
      echo -e "${YELLOW}[*] Found mounted filesystems in $dir_name:${NC}"
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
      echo -e "${GREEN}[+] No mounted filesystems found in $dir_name${NC}"
    fi
  else
    echo -e "${GREEN}[+] No chroot directory found in $dir_name, skipping chroot mount cleanup${NC}"
  fi
  
  # Double-check with a more aggressive approach for any remaining mounts
  echo -e "${YELLOW}[*] Performing final mount cleanup for $dir_name...${NC}"

  # Try to unmount any remaining mounts under this workdir
  REMAINING_MOUNTS=$(mount | grep "$workdir" | awk '{print $3}' | sort -r || true)
  if [ -n "$REMAINING_MOUNTS" ]; then
    echo -e "${YELLOW}[*] Found remaining mounts in $dir_name, attempting cleanup...${NC}"
    for mount_point in $REMAINING_MOUNTS; do
      echo -e "${YELLOW}    Force unmounting $mount_point...${NC}"
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
  echo -e "${GREEN}[+] No build directories to clean up mounts for${NC}"
fi

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# LOOP DEVICE CLEANUP
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

echo
echo -e "${YELLOW}[*] Cleaning up loop devices...${NC}"

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
    echo -e "${YELLOW}       $loop_dev${NC}"
  done
  echo
  
  for loop_dev in "${ALL_LOOP_DEVICES[@]}"; do
    echo -e "${YELLOW}    Detaching $loop_dev...${NC}"
    losetup -d "$loop_dev" 2>/dev/null || true
  done
else
  echo -e "${GREEN}[+] No loop devices found associated with build workspaces${NC}"
fi

# Also check for any orphaned loop devices from ISO files
echo -e "${YELLOW}[*] Checking for orphaned loop devices...${NC}"
ORPHANED_LOOPS=$(losetup -l 2>/dev/null | grep -E "\.(iso|img)$" | awk '{print $1}' || true)

if [ -n "$ORPHANED_LOOPS" ]; then
  echo -e "${YELLOW}[*] Found potentially orphaned loop devices:${NC}"
  losetup -l | grep -E "\.(iso|img)$" || true
  echo
  read -p "Detach these loop devices? (y/N): " DETACH_ORPHANED
  
  if [[ "$DETACH_ORPHANED" =~ ^[Yy]$ ]]; then
    while IFS= read -r loop_dev; do
      if [ -n "$loop_dev" ]; then
        echo -e "${YELLOW}    Detaching $loop_dev...${NC}"
        losetup -d "$loop_dev" 2>/dev/null || true
      fi
    done <<< "$ORPHANED_LOOPS"
  else
    echo -e "${GREEN}    Skipping orphaned loop device cleanup${NC}"
  fi
else
  echo -e "${GREEN}[+] No orphaned loop devices found${NC}"
fi

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# DIRECTORY CLEANUP
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

echo
echo -e "${YELLOW}[*] Removing build directories...${NC}"

# Function to safely remove a directory
safe_remove_directory() {
  local workdir="$1"
  local dir_name=$(basename "$workdir")
  
  if [ -d "$workdir" ]; then
    echo -e "${YELLOW}    Build directory $dir_name exists, attempting removal...${NC}"

    # First attempt: regular removal
    if rm -rf "$workdir" 2>/dev/null; then
      echo -e "${GREEN}    ✓ Build directory $dir_name removed successfully${NC}"
      return 0
    else
      echo -e "${YELLOW}    Regular removal failed for $dir_name, trying alternative methods...${NC}"

      # Second attempt: change permissions and try again
      echo -e "${YELLOW}    Changing permissions for $dir_name and retrying...${NC}"
      chmod -R 777 "$workdir" 2>/dev/null || true
      if rm -rf "$workdir" 2>/dev/null; then
        echo -e "${GREEN}    ✓ Build directory $dir_name removed after permission change${NC}"
        return 0
      else
        # Third attempt: Remove contents first, then directory
        echo -e "${YELLOW}    Removing contents individually for $dir_name...${NC}"
        find "$workdir" -type f -delete 2>/dev/null || true
        find "$workdir" -depth -type d -exec rmdir {} \; 2>/dev/null || true
        
        if [ ! -d "$workdir" ]; then
          echo -e "${GREEN}    ✓ Build directory $dir_name removed after individual cleanup${NC}"
          return 0
        else
          echo -e "${YELLOW}    ⚠ Some files/directories may remain in $workdir${NC}"
          echo -e "${YELLOW}    You may need to manually remove them or reboot${NC}"

          # Show what's left
          echo -e "${YELLOW}    Remaining items in $dir_name:${NC}"
          ls -la "$workdir" 2>/dev/null || true
          return 1
        fi
      fi
    fi
  else
    echo -e "${GREEN}    ✓ Build directory $dir_name does not exist${NC}"
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
  echo -e "${GREEN}[+] No build directories to remove${NC}"
fi

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# SYSTEM CLEANUP
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

echo
echo -e "${YELLOW}[*] Performing system cleanup...${NC}"

# Clear any cached filesystem information
echo -e "${YELLOW}    Clearing filesystem caches...${NC}"
sync
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

# Trigger udev to rescan devices
echo -e "${YELLOW}    Triggering udev rescan...${NC}"
udevadm control --reload 2>/dev/null || true
udevadm trigger 2>/dev/null || true
udevadm settle 2>/dev/null || true

# Update the locate database if updatedb is available
if command -v updatedb >/dev/null 2>&1; then
  echo -e "${YELLOW}    Updating locate database...${NC}"
  updatedb 2>/dev/null || true
fi

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
# VERIFICATION AND COMPLETION
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

echo
echo -e "${YELLOW}[*] Verification...${NC}"

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
  echo -e "${RED}    ⚠ Warning: Some mounts may still exist:${NC}"
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
  echo -e "${RED}    ⚠ Warning: Some build directories still exist:${NC}"
  for dir in "${REMAINING_DIRS[@]}"; do
    echo -e "${RED}       - $dir${NC}"
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
  echo -e "${RED}    ⚠ Warning: Some processes may still be using build directories${NC}"
  CLEANUP_SUCCESS=false
fi

# Factor in directory removal issues
if [ "$REMOVAL_ISSUES" = true ]; then
  CLEANUP_SUCCESS=false
fi

echo
if [ "$CLEANUP_SUCCESS" = true ]; then
  echo "════════════════════════════════════════════════════════════════════════════════════════"
  echo -e "${GREEN}✓ CLEANUP COMPLETED SUCCESSFULLY${NC}"
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
  echo -e "${RED}⚠ CLEANUP COMPLETED WITH WARNINGS${NC}"
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