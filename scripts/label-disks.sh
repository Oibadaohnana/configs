#!/usr/bin/env bash
set -euo pipefail

# Devices to label
BOOT_DEV="/dev/sda1"
ROOT_DEV="/dev/nvme0n1p1"

# Desired labels
BOOT_LABEL="BOOT"
ROOT_LABEL="root-partition"

echo "Starting disk labeling..."

# Function to get current label (works for ext4 and vfat)
get_label() {
  local dev=$1
  blkid -o value -s LABEL "$dev" || echo ""
}

# Label vfat partition using fatlabel
label_vfat() {
  local dev=$1
  local label=$2
  current_label=$(get_label "$dev")
  if [[ "$current_label" != "$label" ]]; then
    echo "Labeling $dev as $label (vfat)..."
    sudo fatlabel "$dev" "$label"
  else
    echo "$dev already labeled as $label"
  fi
}

# Label ext4 partition using tune2fs
label_ext4() {
  local dev=$1
  local label=$2
  current_label=$(get_label "$dev")
  if [[ "$current_label" != "$label" ]]; then
    echo "Labeling $dev as $label (ext4)..."
    sudo tune2fs -L "$label" "$dev"
  else
    echo "$dev already labeled as $label"
  fi
}

# Label partitions
label_vfat "$BOOT_DEV" "$BOOT_LABEL"
label_ext4 "$ROOT_DEV" "$ROOT_LABEL"

# Trigger udev to refresh /dev/disk/by-label
echo "Refreshing udev links..."
sudo udevadm trigger

# Show final labels
echo "Current labels in /dev/disk/by-label:"
ls -l /dev/disk/by-label

echo "Disk labeling complete."
