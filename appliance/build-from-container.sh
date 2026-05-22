#!/bin/bash
set -euo pipefail

# Build VM appliance from openSUSE container image
# This bypasses KIWI's rpm database caching issues in GitHub Actions

TARGET_DIR="${1:-appliance/build}"
IMAGE_SIZE="${2:-2G}"
CONTAINER_IMAGE="registry.opensuse.org/opensuse/tumbleweed:latest"

echo "Building incus-spawn appliance from container..."
echo "  Container:   $CONTAINER_IMAGE"
echo "  Target:      $TARGET_DIR"
echo "  Image size:  $IMAGE_SIZE"
echo

# Create target directory
mkdir -p "$TARGET_DIR"

# Create a sparse qcow2 image
DISK_IMAGE="$TARGET_DIR/incus-spawn-appliance.qcow2"
echo "Creating disk image..."
qemu-img create -f qcow2 "$DISK_IMAGE" "$IMAGE_SIZE"

# Create a temporary mount point
MOUNT_DIR=$(mktemp -d)
NBD_DEVICE="/dev/nbd0"

cleanup() {
    echo "Cleaning up..."
    sync
    umount "$MOUNT_DIR" 2>/dev/null || true
    qemu-nbd --disconnect "$NBD_DEVICE" 2>/dev/null || true
    rmdir "$MOUNT_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# Load nbd kernel module
echo "Loading nbd module..."
modprobe nbd max_part=8

# Connect qcow2 to NBD
echo "Connecting image to NBD device..."
qemu-nbd --connect="$NBD_DEVICE" "$DISK_IMAGE"

# Wait for device
sleep 1

# Create partition table and partition
echo "Creating partition table..."
parted -s "$NBD_DEVICE" mklabel gpt
parted -s "$NBD_DEVICE" mkpart primary ext4 1MiB 100%

# Wait for partition device
sleep 1
PART_DEVICE="${NBD_DEVICE}p1"

# Format partition
echo "Creating ext4 filesystem..."
mkfs.ext4 -F "$PART_DEVICE"

# Mount partition
echo "Mounting partition..."
mount "$PART_DEVICE" "$MOUNT_DIR"

# Extract container rootfs
echo "Extracting container rootfs..."
podman pull "$CONTAINER_IMAGE"
CONTAINER_ID=$(podman create "$CONTAINER_IMAGE")
podman export "$CONTAINER_ID" | tar -xC "$MOUNT_DIR"
podman rm "$CONTAINER_ID"

# Install packages needed for a bootable VM
echo "Installing additional packages via chroot..."
mount --bind /dev "$MOUNT_DIR/dev"
mount --bind /proc "$MOUNT_DIR/proc"
mount --bind /sys "$MOUNT_DIR/sys"

# Copy DNS configuration for network access in chroot
cp /etc/resolv.conf "$MOUNT_DIR/etc/resolv.conf"

cleanup_chroot() {
    umount "$MOUNT_DIR/dev" 2>/dev/null || true
    umount "$MOUNT_DIR/proc" 2>/dev/null || true
    umount "$MOUNT_DIR/sys" 2>/dev/null || true
}
trap cleanup_chroot EXIT

# Configure zypper repos
cat > "$MOUNT_DIR/etc/zypp/repos.d/repo-oss.repo" <<EOF
[repo-oss]
name=openSUSE Tumbleweed OSS
enabled=1
autorefresh=1
baseurl=https://download.opensuse.org/tumbleweed/repo/oss/
type=rpm-md
keeppackages=0
EOF

# Install kernel, bootloader, and other essentials
chroot "$MOUNT_DIR" /bin/bash -c "
set -euo pipefail
zypper --non-interactive refresh
zypper --non-interactive install --no-recommends \
    kernel-default \
    dracut \
    grub2 \
    systemd \
    systemd-network \
    iproute2 \
    iptables \
    incus \
    btrfs-progs \
    openssh-server \
    ca-certificates \
    ca-certificates-mozilla
"

# Copy overlay files BEFORE config.sh so systemd units exist
if [ -d "appliance/root" ]; then
    echo "Copying overlay files..."
    cp -a appliance/root/* "$MOUNT_DIR/"
fi

# Run config.sh customization script if it exists
if [ -f "appliance/config.sh" ]; then
    echo "Running config.sh customization..."
    cp appliance/config.sh "$MOUNT_DIR/config.sh"
    chmod +x "$MOUNT_DIR/config.sh"
    chroot "$MOUNT_DIR" /config.sh
    rm "$MOUNT_DIR/config.sh"
fi

# Install bootloader
echo "Installing GRUB..."
chroot "$MOUNT_DIR" grub2-install --target=i386-pc "$NBD_DEVICE"
chroot "$MOUNT_DIR" grub2-mkconfig -o /boot/grub2/grub.cfg

# Set up fstab
echo "Configuring fstab..."
cat > "$MOUNT_DIR/etc/fstab" <<EOF
/dev/vda1  /  ext4  defaults,noatime  0  1
EOF

# Clean up package caches
echo "Cleaning package caches..."
chroot "$MOUNT_DIR" zypper clean --all || true

cleanup_chroot
cleanup

echo
echo "Build complete!"
echo "Image: $DISK_IMAGE"
ls -lh "$DISK_IMAGE"
qemu-img info "$DISK_IMAGE"
