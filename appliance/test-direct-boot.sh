#!/bin/bash
# Test the appliance image with QEMU direct kernel boot.
# This is the production boot path - bypasses GRUB entirely.

set -euo pipefail

IMAGE="${1:-build/incus-spawn-appliance.qcow2}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -f "$IMAGE" ]; then
    echo "ERROR: Image not found: $IMAGE" >&2
    echo "Usage: $0 [path-to-image.qcow2]" >&2
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must be run as root (needs qemu-nbd)" >&2
    exit 1
fi

echo "Extracting kernel and initrd from image..."

# Mount image via NBD
modprobe nbd max_part=8
qemu-nbd --connect=/dev/nbd0 "$IMAGE"
sleep 1

# Find root partition (usually p3 in OEM images)
MOUNT_DIR=$(mktemp -d)
trap "umount $MOUNT_DIR 2>/dev/null || true; qemu-nbd --disconnect /dev/nbd0; rmdir $MOUNT_DIR" EXIT

if mount /dev/nbd0p3 "$MOUNT_DIR" 2>/dev/null; then
    echo "Mounted /dev/nbd0p3"
elif mount /dev/nbd0p2 "$MOUNT_DIR" 2>/dev/null; then
    echo "Mounted /dev/nbd0p2"
elif mount /dev/nbd0p1 "$MOUNT_DIR" 2>/dev/null; then
    echo "Mounted /dev/nbd0p1"
else
    echo "ERROR: Failed to mount any partition" >&2
    exit 1
fi

# Extract kernel (from /lib/modules with initrd_system="none")
KERNEL=$(find "$MOUNT_DIR/lib/modules" -name 'vmlinuz' -type f | head -1)
if [ -z "$KERNEL" ]; then
    echo "ERROR: No kernel found in /lib/modules" >&2
    exit 1
fi

KERNEL_VERSION=$(basename "$(dirname "$KERNEL")")
cp "$KERNEL" "/tmp/vmlinuz-$KERNEL_VERSION"
echo "  Kernel: /tmp/vmlinuz-$KERNEL_VERSION"

# Check for initrd (might not exist with initrd_system="none")
INITRD=$(find "$MOUNT_DIR/boot" -name "initrd-${KERNEL_VERSION}*" -o -name "initramfs-${KERNEL_VERSION}*" | head -1)
INITRD_ARG=""
if [ -n "$INITRD" ] && [ -f "$INITRD" ]; then
    cp "$INITRD" "/tmp/initrd-$KERNEL_VERSION"
    INITRD_ARG="-initrd /tmp/initrd-$KERNEL_VERSION"
    echo "  Initrd: /tmp/initrd-$KERNEL_VERSION"
else
    echo "  Initrd: none (direct boot)"
fi

# Get root UUID
ROOT_UUID=$(findmnt -n -o UUID "$MOUNT_DIR" || blkid -s UUID -o value /dev/nbd0p3 2>/dev/null || blkid -s UUID -o value /dev/nbd0p2 2>/dev/null || echo "")

umount "$MOUNT_DIR"
qemu-nbd --disconnect /dev/nbd0
rmdir "$MOUNT_DIR"

if [ -z "$ROOT_UUID" ]; then
    echo "WARNING: Could not determine root UUID, using /dev/vda3" >&2
    ROOT_DEV="/dev/vda3"
else
    ROOT_DEV="UUID=$ROOT_UUID"
fi

echo ""
echo "Booting with QEMU (direct kernel boot)..."
echo ""

exec qemu-system-x86_64 \
    -machine q35 \
    -enable-kvm \
    -cpu host \
    -m 2G \
    -smp 2 \
    -kernel "/tmp/vmlinuz-$KERNEL_VERSION" \
    $INITRD_ARG \
    -append "root=$ROOT_DEV console=ttyS0 quiet systemd.show_status=no rw" \
    -drive file="$IMAGE",format=qcow2,if=virtio \
    -netdev user,id=net0,hostfwd=tcp::2222-:22 \
    -device virtio-net-pci,netdev=net0 \
    -nographic
