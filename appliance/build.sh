#!/bin/bash
# Build the incus-spawn VM appliance image using KIWI NG.
#
# KIWI uses chroot with /dev bind mounts, so this script CANNOT run inside
# a container (Incus, Docker, etc.) — it needs a real VM or bare-metal host.
# In CI, this runs on a GitHub Actions runner (ubuntu-latest) with zypper
# installed. Locally, run on your host or inside a VM.
#
# Requires: kiwi-ng (pip install kiwi), zypper, root privileges.
#
# Usage:
#   sudo ./build.sh                          # Build with default settings
#   sudo ./build.sh --target-dir /tmp/out    # Custom output directory
#   sudo ./build.sh --clean                  # Clean target before build

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_DIR="${TARGET_DIR:-${SCRIPT_DIR}/build}"
REPO_URL="https://download.opensuse.org/tumbleweed/repo/oss/"
IMAGE_NAME="incus-spawn-appliance"
CLEAN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target-dir)
            TARGET_DIR="$2"
            shift 2
            ;;
        --repo)
            REPO_URL="$2"
            shift 2
            ;;
        --clean)
            CLEAN=true
            shift
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: $0 [--target-dir DIR] [--repo URL] [--clean]" >&2
            exit 1
            ;;
    esac
done

if ! command -v kiwi-ng > /dev/null 2>&1; then
    echo "ERROR: kiwi-ng not found. Install with: pip install kiwi" >&2
    exit 1
fi

if ! command -v zypper > /dev/null 2>&1; then
    echo "ERROR: zypper not found. On Fedora/RHEL: dnf install zypper" >&2
    echo "       On Debian/Ubuntu: apt install zypper" >&2
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must be run as root (KIWI needs loopback devices and mount)" >&2
    exit 1
fi

if [ -f /dev/.incus-mounts ] || [ -f /.dockerenv ]; then
    echo "ERROR: cannot build inside a container (KIWI needs real /dev access)." >&2
    echo "       Run on bare metal, in a VM, or via CI." >&2
    exit 1
fi

# Check for SELinux issues
if command -v getenforce > /dev/null 2>&1; then
    if [ "$(getenforce)" = "Enforcing" ]; then
        echo "WARNING: SELinux is enforcing. If the build fails with permission errors," >&2
        echo "         run: sudo setenforce 0 (before build) && sudo setenforce 1 (after)" >&2
    fi
fi

# Clean previous build if requested or if build directory exists
if [ "$CLEAN" = true ] || [ -d "${TARGET_DIR}/build" ]; then
    if [ "$CLEAN" = true ]; then
        echo "Cleaning previous build..."
    else
        echo "Detected previous build artifacts, cleaning..."
    fi
    # Unmount any leftover mounts from failed builds
    for mount in $(mount | grep "${TARGET_DIR}/build/image-root" | awk '{print $3}' | sort -r); do
        umount -l "$mount" 2>/dev/null || true
    done
    rm -rf "${TARGET_DIR}/build" 2>/dev/null || true
fi

echo "Building incus-spawn appliance..."
echo "  Description: ${SCRIPT_DIR}"
echo "  Target:      ${TARGET_DIR}"
echo "  Repository:  ${REPO_URL}"
echo ""

mkdir -p "${TARGET_DIR}"

# Trap cleanup on error
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo "" >&2
        echo "Build failed with exit code ${exit_code}" >&2
        echo "Cleaning up mounts..." >&2
        for mount in $(mount | grep "${TARGET_DIR}/build/image-root" | awk '{print $3}' | sort -r); do
            umount -l "$mount" 2>/dev/null || true
        done
        echo "Build artifacts left in: ${TARGET_DIR}/build" >&2
        echo "To retry: sudo ./build.sh --clean --target-dir ${TARGET_DIR}" >&2
    fi
}
trap cleanup EXIT

echo "Running KIWI NG build (this will take several minutes)..."
echo ""

kiwi-ng system build \
    --description "${SCRIPT_DIR}" \
    --target-dir "${TARGET_DIR}" \
    --set-repo "${REPO_URL}"

echo ""
echo "KIWI build complete. Processing output..."

QCOW2=$(find "${TARGET_DIR}" -name "*.qcow2" -type f | head -1)
if [ -n "$QCOW2" ]; then
    SIZE=$(du -sh "$QCOW2" | cut -f1)
    echo ""
    echo "Build complete:"
    echo "  Image: ${QCOW2}"
    echo "  Size:  ${SIZE}"

    COMPRESSED="${TARGET_DIR}/${IMAGE_NAME}.qcow2"
    if [ "$QCOW2" != "$COMPRESSED" ] && command -v qemu-img > /dev/null 2>&1; then
        echo ""
        echo "Compressing image..."
        qemu-img convert -c -O qcow2 "$QCOW2" "$COMPRESSED"
        CSIZE=$(du -sh "$COMPRESSED" | cut -f1)
        echo "  Compressed: ${COMPRESSED} (${CSIZE})"

        # Show image info
        echo ""
        echo "Image details:"
        qemu-img info "$COMPRESSED" | grep -E 'virtual size|disk size'
    fi

    echo ""
    echo "Success! VM appliance ready at: ${COMPRESSED:-${QCOW2}}"
    echo ""
    echo "To test locally:"
    echo "  qemu-system-x86_64 -machine q35 -enable-kvm -cpu host -m 2G -smp 2 \\"
    echo "    -drive file=${COMPRESSED:-${QCOW2}},format=qcow2,if=virtio \\"
    echo "    -netdev user,id=net0,hostfwd=tcp::2222-:22 -device virtio-net-pci,netdev=net0 \\"
    echo "    -nographic"
else
    echo "ERROR: No qcow2 image found in ${TARGET_DIR}" >&2
    echo "Build may have failed. Check output above for errors." >&2
    ls -la "${TARGET_DIR}/" || true
    exit 1
fi
