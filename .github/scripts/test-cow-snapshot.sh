#!/bin/bash
# Integration test: branching a template must not duplicate its disk footprint.
#
# Measures actual disk usage (du) of the storage pool's container directory
# before and after branching.  On a CoW-capable backend (btrfs, ZFS), the
# branch adds negligible overhead; on a dir backend a full copy is expected
# without further optimisation.
#
# Requires:
#   - tpl-minimal already built
#   - isx and incus available on PATH
#   - sudo access for du on the pool directory
#
# Usage:
#   .github/scripts/test-cow-snapshot.sh
#   sg incus-admin -c "bash .github/scripts/test-cow-snapshot.sh"

set -euo pipefail

TESTS=0
PASS=0
FAIL=0

assert_lt() {
    local desc="$1" actual="$2" threshold="$3"
    TESTS=$((TESTS + 1))
    if [ "$actual" -lt "$threshold" ]; then
        printf '  \033[32mPASS\033[0m  %s  (actual: %s)\n' "$desc" "$actual"
        PASS=$((PASS + 1))
    else
        printf '  \033[31mFAIL\033[0m  %s  (actual: %s, threshold: %s)\n' \
            "$desc" "$actual" "$threshold"
        FAIL=$((FAIL + 1))
    fi
}

# Find which pool holds tpl-minimal by checking each pool for the volume.
find_template_pool() {
    for pool in $(incus storage list -f csv | cut -d, -f1); do
        if incus storage volume list "$pool" -f csv 2>/dev/null \
                | grep -q "^container,tpl-minimal,"; then
            echo "$pool"
            return
        fi
    done
    echo ""
}

# Total disk usage in MB of a directory.
du_mb() {
    sudo du -sm "$1" 2>/dev/null | cut -f1
}

echo "========================================"
echo " CoW disk overhead integration tests"
echo "========================================"
echo ""

POOL=$(find_template_pool)
if [ -z "$POOL" ]; then
    echo "  ERROR: tpl-minimal not found on any storage pool"
    exit 1
fi
DRIVER=$(incus storage list -f csv | grep "^$POOL," | cut -d, -f2)
CONTAINERS_DIR="/var/lib/incus/storage-pools/$POOL/containers"

echo "  Pool:                $POOL"
echo "  Driver:              $DRIVER"
echo "  Pool containers dir: $CONTAINERS_DIR"
echo ""

# --- 1. Measure template size ---
echo "--- 1. Template disk usage ---"
TPL_DIR="$CONTAINERS_DIR/tpl-minimal"
if [ ! -d "$TPL_DIR" ]; then
    echo "  ERROR: $TPL_DIR does not exist"
    echo "  Available: $(sudo ls "$CONTAINERS_DIR" 2>/dev/null || echo '(none)')"
    exit 1
fi
TPL_MB=$(du_mb "$TPL_DIR")
echo "  Template size: ${TPL_MB}MB"
echo ""

# --- 2. Branch and measure overhead ---
echo "--- 2. Branch disk overhead ---"
BEFORE_MB=$(du_mb "$CONTAINERS_DIR")

isx branch cow-test-branch --from tpl-minimal --no-start 2>&1

AFTER_MB=$(du_mb "$CONTAINERS_DIR")
DELTA_MB=$((AFTER_MB - BEFORE_MB))
if [ "$DELTA_MB" -lt 0 ]; then DELTA_MB=0; fi

echo "  Pool containers before branch: ${BEFORE_MB}MB"
echo "  Pool containers after branch:  ${AFTER_MB}MB"
echo "  Branch overhead:               ${DELTA_MB}MB"
echo "  Template size for reference:   ${TPL_MB}MB"

# A full copy would add ~TPL_MB. CoW should add far less.
# Threshold: 20% of template size or 50MB, whichever is larger.
THRESHOLD=$((TPL_MB / 5))
if [ "$THRESHOLD" -lt 50 ]; then THRESHOLD=50; fi

assert_lt "Branch overhead (${DELTA_MB}MB) is under ${THRESHOLD}MB (20% of template)" \
    "$DELTA_MB" "$THRESHOLD"

echo ""

# --- Cleanup ---
echo "--- Cleanup ---"
isx destroy cow-test-branch 2>&1

echo ""
echo "========================================"
if [ "$FAIL" -gt 0 ]; then
    echo " $PASS/$TESTS passed, $FAIL FAILED"
    exit 1
fi
echo " All $TESTS tests passed"
echo "========================================"
