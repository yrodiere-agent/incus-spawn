#!/bin/bash
# Diagnostic script for troubleshooting appliance build issues.
# Run with: sudo ./appliance/diagnose.sh

set -euo pipefail

echo "=== KIWI Appliance Build Diagnostics ==="
echo "Date: $(date)"
echo ""

echo "=== System Info ==="
uname -a
echo ""

echo "=== SELinux Status ==="
if command -v getenforce > /dev/null 2>&1; then
    getenforce
else
    echo "SELinux not installed"
fi
echo ""

echo "=== Loop Devices ==="
losetup -a || echo "No loop devices active"
echo ""

echo "=== Loop Device Details ==="
for loop in /dev/loop*[0-9]; do
    if [ -b "$loop" ]; then
        echo "--- $loop ---"
        losetup "$loop" 2>&1 || echo "  Not configured"
        if [ -e "/sys/block/$(basename $loop)/loop/autoclear" ]; then
            echo "  Autoclear: $(cat /sys/block/$(basename $loop)/loop/autoclear)"
        fi
        partx -l "$loop" 2>&1 || echo "  No partitions or device not set up"
        echo ""
    fi
done
echo ""

echo "=== Device Mapper ==="
dmsetup ls 2>&1 || echo "No device mapper targets"
echo ""

echo "=== NBD Devices ==="
if lsmod | grep -q nbd; then
    echo "NBD module loaded"
    for nbd in /dev/nbd*[0-9]; do
        if [ -b "$nbd" ]; then
            nbd-client -c "$nbd" 2>&1 || echo "$nbd: not connected"
        fi
    done
else
    echo "NBD module not loaded"
fi
echo ""

echo "=== Mount Points (appliance-related) ==="
mount | grep -E 'loop|nbd|appliance|/tmp/img|kiwi' || echo "No appliance mounts"
echo ""

echo "=== Build Artifacts ==="
if [ -d "/var/tmp/appliance-build" ]; then
    echo "Build directory exists:"
    ls -lh /var/tmp/appliance-build/*.{qcow2,raw,img} 2>/dev/null || echo "  No image files"
    echo ""
    if [ -d "/var/tmp/appliance-build/build" ]; then
        echo "Build subdirectory size:"
        du -sh /var/tmp/appliance-build/build 2>/dev/null || echo "  Cannot read"
    fi
else
    echo "Build directory does not exist: /var/tmp/appliance-build"
fi
echo ""

echo "=== Recent Kernel Messages (loop/partx/kiwi) ==="
dmesg | grep -iE 'loop|partx|kiwi|device-mapper' | tail -30 || echo "No relevant messages"
echo ""

echo "=== Processes Using Loop Devices ==="
lsof 2>/dev/null | grep loop || echo "No processes using loop devices"
echo ""

echo "=== Disk Space ==="
df -h /var/tmp 2>/dev/null || df -h /tmp
echo ""

echo "=== KIWI Version ==="
if command -v kiwi-ng > /dev/null 2>&1; then
    kiwi-ng --version 2>&1 || echo "kiwi-ng found but version check failed"
else
    echo "kiwi-ng not found in PATH"
fi
echo ""

echo "=== Container Detection ==="
if [ -f /dev/.incus-mounts ]; then
    echo "Running inside Incus container (NOT SUPPORTED for KIWI builds)"
elif [ -f /.dockerenv ]; then
    echo "Running inside Docker container (NOT SUPPORTED for KIWI builds)"
else
    echo "Not inside a container (OK for KIWI builds)"
fi
echo ""

echo "=== Diagnostics Complete ==="
