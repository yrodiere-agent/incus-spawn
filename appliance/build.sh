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

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_DIR="${TARGET_DIR:-${SCRIPT_DIR}/build}"
REPO_URL="https://download.opensuse.org/tumbleweed/repo/oss/"
IMAGE_NAME="incus-spawn-appliance"

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
        *)
            echo "Unknown option: $1" >&2
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

echo "Building incus-spawn appliance..."
echo "  Description: ${SCRIPT_DIR}"
echo "  Target:      ${TARGET_DIR}"
echo "  Repository:  ${REPO_URL}"

mkdir -p "${TARGET_DIR}"

kiwi-ng system build \
    --description "${SCRIPT_DIR}" \
    --target-dir "${TARGET_DIR}" \
    --set-repo "${REPO_URL}"

QCOW2=$(find "${TARGET_DIR}" -name "*.qcow2" -type f | head -1)
if [ -n "$QCOW2" ]; then
    SIZE=$(du -sh "$QCOW2" | cut -f1)
    echo ""
    echo "Build complete:"
    echo "  Image: ${QCOW2}"
    echo "  Size:  ${SIZE}"

    COMPRESSED="${TARGET_DIR}/${IMAGE_NAME}.qcow2"
    if [ "$QCOW2" != "$COMPRESSED" ] && command -v qemu-img > /dev/null 2>&1; then
        echo "  Compressing..."
        qemu-img convert -c -O qcow2 "$QCOW2" "$COMPRESSED"
        CSIZE=$(du -sh "$COMPRESSED" | cut -f1)
        echo "  Compressed: ${COMPRESSED} (${CSIZE})"
    fi
else
    echo "WARNING: No qcow2 image found in ${TARGET_DIR}" >&2
    ls -la "${TARGET_DIR}/"
fi
