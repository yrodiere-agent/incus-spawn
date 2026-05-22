#!/bin/bash
set -euo pipefail

# Build VM appliance from openSUSE container image.
# No block devices or KVM required — works inside containers.
#
# Strategy: build rootfs in a directory via podman+chroot, then pack
# it into a raw ext4 image using mkfs.ext4 + debugfs, convert to qcow2.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_DIR="${1:-$SCRIPT_DIR/build}"
IMAGE_SIZE="${2:-2G}"
CONTAINER_IMAGE="registry.opensuse.org/opensuse/tumbleweed:latest"

echo "Building incus-spawn appliance..."
echo "  Container:   $CONTAINER_IMAGE"
echo "  Target:      $TARGET_DIR"
echo "  Image size:  $IMAGE_SIZE"
echo

mkdir -p "$TARGET_DIR"

ROOTFS_DIR=$(mktemp -d)
DISK_IMAGE="$TARGET_DIR/incus-spawn-appliance.qcow2"
RAW_IMAGE=$(mktemp --suffix=.raw)

cleanup() {
    echo "Cleaning up..."
    umount "$ROOTFS_DIR/dev" 2>/dev/null || true
    umount "$ROOTFS_DIR/proc" 2>/dev/null || true
    umount "$ROOTFS_DIR/sys" 2>/dev/null || true
    rm -rf "$ROOTFS_DIR"
    rm -f "$RAW_IMAGE"
}
trap cleanup EXIT

# --- Step 1: Extract container rootfs ---
echo "==> Extracting container rootfs..."
podman pull "$CONTAINER_IMAGE"
CONTAINER_ID=$(podman create "$CONTAINER_IMAGE")
podman export "$CONTAINER_ID" | tar -xC "$ROOTFS_DIR"
podman rm "$CONTAINER_ID"
echo "    Rootfs size: $(du -sh "$ROOTFS_DIR" | cut -f1)"

# --- Step 2: Set up chroot environment ---
echo "==> Setting up chroot..."
mount --bind /dev "$ROOTFS_DIR/dev"
mount --bind /proc "$ROOTFS_DIR/proc"
mount --bind /sys "$ROOTFS_DIR/sys"
cp /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf"

# --- Step 3: Install packages via chroot ---
echo "==> Installing packages..."
chroot "$ROOTFS_DIR" /bin/bash -c "
set -euo pipefail
zypper --non-interactive refresh
zypper --non-interactive install --no-recommends \
    kernel-default \
    dracut \
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
echo "    Rootfs size after packages: $(du -sh "$ROOTFS_DIR" | cut -f1)"

# --- Step 4: Copy overlay files ---
if [ -d "$SCRIPT_DIR/root" ]; then
    echo "==> Copying overlay files..."
    cp -a "$SCRIPT_DIR/root"/* "$ROOTFS_DIR/"
fi

# --- Step 5: Run config.sh ---
if [ -f "$SCRIPT_DIR/config.sh" ]; then
    echo "==> Running config.sh..."
    cp "$SCRIPT_DIR/config.sh" "$ROOTFS_DIR/config.sh"
    chmod +x "$ROOTFS_DIR/config.sh"
    chroot "$ROOTFS_DIR" /config.sh
    rm "$ROOTFS_DIR/config.sh"
fi

# --- Step 6: Set up fstab and boot config ---
echo "==> Configuring boot..."
cat > "$ROOTFS_DIR/etc/fstab" <<EOF
/dev/vda1  /  ext4  defaults,noatime  0  1
EOF

KERNEL_VERSION=$(ls "$ROOTFS_DIR/lib/modules/" | head -1)
echo "    Kernel: $KERNEL_VERSION"

# --- Step 7: Clean up rootfs ---
echo "==> Cleaning up rootfs..."
chroot "$ROOTFS_DIR" zypper clean --all 2>/dev/null || true
rm -rf "$ROOTFS_DIR/var/cache/zypp" "$ROOTFS_DIR/var/log/zypp"
rm -rf "$ROOTFS_DIR/usr/share/man" "$ROOTFS_DIR/usr/share/doc" "$ROOTFS_DIR/usr/share/info"
rm -rf "$ROOTFS_DIR/tmp/"* "$ROOTFS_DIR/var/tmp/"*

# Unmount chroot bind mounts before creating image
umount "$ROOTFS_DIR/dev" 2>/dev/null || true
umount "$ROOTFS_DIR/proc" 2>/dev/null || true
umount "$ROOTFS_DIR/sys" 2>/dev/null || true

echo "    Final rootfs size: $(du -sh "$ROOTFS_DIR" | cut -f1)"

# --- Step 8: Create disk image ---
echo "==> Creating raw disk image..."

# Create sparse raw image
truncate -s "$IMAGE_SIZE" "$RAW_IMAGE"

# Create ext4 filesystem on it (no mount needed!)
mkfs.ext4 -F -d "$ROOTFS_DIR" "$RAW_IMAGE"

echo "==> Converting to qcow2..."
qemu-img convert -f raw -O qcow2 -c "$RAW_IMAGE" "$DISK_IMAGE"
rm -f "$RAW_IMAGE"

# --- Step 9: Extract kernel and initrd for direct boot ---
echo "==> Extracting kernel and initrd for direct boot..."
cp "$ROOTFS_DIR/boot/vmlinuz-$KERNEL_VERSION" "$TARGET_DIR/vmlinuz"
if [ -f "$ROOTFS_DIR/boot/initrd-$KERNEL_VERSION" ]; then
    cp "$ROOTFS_DIR/boot/initrd-$KERNEL_VERSION" "$TARGET_DIR/initrd"
else
    echo "    WARNING: no initrd found, generating..."
    chroot "$ROOTFS_DIR" dracut --no-hostonly --force --kver "$KERNEL_VERSION" "/boot/initrd" 2>/dev/null || true
    cp "$ROOTFS_DIR/boot/initrd" "$TARGET_DIR/initrd" 2>/dev/null || echo "    WARNING: initrd generation failed (expected in container)"
fi

# Ensure all output files are readable
chmod 644 "$DISK_IMAGE" "$TARGET_DIR/vmlinuz"
[ -f "$TARGET_DIR/initrd" ] && chmod 644 "$TARGET_DIR/initrd"

echo
echo "Build complete!"
echo "  Image:  $DISK_IMAGE"
echo "  Kernel: $TARGET_DIR/vmlinuz"
ls -lh "$DISK_IMAGE" "$TARGET_DIR/vmlinuz"
[ -f "$TARGET_DIR/initrd" ] && ls -lh "$TARGET_DIR/initrd"
qemu-img info "$DISK_IMAGE"
