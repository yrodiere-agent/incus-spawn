#!/bin/bash
# Integration test: branching a template must not duplicate its disk footprint.
#
# Collects multiple disk metrics before and after branching to distinguish
# real data duplication from btrfs shared-block accounting:
#
#   - du -sm:          filesystem-reported size (on btrfs, counts shared/
#                      referenced blocks per subvolume — can overcount)
#   - pool space.used: actual bytes consumed on the backing device (the
#                      ground truth for "did we use more disk?")
#   - btrfs qgroup:    per-subvolume referenced (rfer) vs exclusive (excl)
#                      bytes, when available
#
# Requires:
#   - tpl-minimal already built
#   - isx and incus on PATH
#   - sudo access (for du and btrfs qgroup)
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

to_mb() { echo $(( $1 / 1024 / 1024 )); }

# Find which pool holds tpl-minimal.
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

# Pool-level used bytes from the Incus API (ground truth).
pool_used_bytes() {
    incus query "/1.0/storage-pools/$1/resources" | jq '.space.used'
}

# du -sm of a directory (filesystem-reported, may overcount on btrfs).
du_mb() {
    sudo du -sm "$1" 2>/dev/null | cut -f1
}

# Dump btrfs qgroup info for all subvolumes on the pool mount.
# Output: subvolume-path  rfer  excl  (in bytes, --raw)
btrfs_qgroups() {
    local mount="$1"
    # Sync to flush pending accounting
    sudo btrfs filesystem sync "$mount" 2>/dev/null || true
    # Join qgroup show with subvolume list to get human-readable paths
    sudo btrfs qgroup show -re --raw "$mount" 2>/dev/null
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
POOL_MOUNT="/var/lib/incus/storage-pools/$POOL"

echo "  Pool:                $POOL"
echo "  Driver:              $DRIVER"
echo "  Pool containers dir: $CONTAINERS_DIR"
echo ""

# Show incus storage list for context (as Sanne requested)
echo "--- Storage pools ---"
incus storage list 2>/dev/null || true
echo ""

# --- 1. Measure template size ---
echo "--- 1. Template disk usage ---"
TPL_DIR="$CONTAINERS_DIR/tpl-minimal"
if [ ! -d "$TPL_DIR" ]; then
    echo "  ERROR: $TPL_DIR does not exist"
    echo "  Available: $(sudo ls "$CONTAINERS_DIR" 2>/dev/null || echo '(none)')"
    exit 1
fi
TPL_DU_MB=$(du_mb "$TPL_DIR")
echo "  Template du -sm: ${TPL_DU_MB}MB"
echo ""

# --- 2. Collect all metrics before branching ---
echo "--- 2. Metrics before branch ---"
POOL_BEFORE=$(pool_used_bytes "$POOL")
DU_BEFORE=$(du_mb "$CONTAINERS_DIR")
echo "  Pool space.used:     $(to_mb "$POOL_BEFORE")MB  ($POOL_BEFORE bytes)"
echo "  du -sm containers/:  ${DU_BEFORE}MB"

if [ "$DRIVER" = "btrfs" ]; then
    echo ""
    echo "  btrfs qgroups (before):"
    btrfs_qgroups "$POOL_MOUNT" || true
fi
echo ""

# --- 3. Branch ---
echo "--- 3. Branching ---"
isx branch cow-test-branch --from tpl-minimal --no-start 2>&1
echo ""

# --- 4. Collect all metrics after branching ---
echo "--- 4. Metrics after branch ---"
POOL_AFTER=$(pool_used_bytes "$POOL")
DU_AFTER=$(du_mb "$CONTAINERS_DIR")
echo "  Pool space.used:     $(to_mb "$POOL_AFTER")MB  ($POOL_AFTER bytes)"
echo "  du -sm containers/:  ${DU_AFTER}MB"

if [ "$DRIVER" = "btrfs" ]; then
    echo ""
    echo "  btrfs qgroups (after):"
    btrfs_qgroups "$POOL_MOUNT" || true
fi
echo ""

# --- 5. Compute deltas ---
echo "--- 5. Deltas ---"
DU_DELTA=$((DU_AFTER - DU_BEFORE))
POOL_DELTA=$((POOL_AFTER - POOL_BEFORE))
if [ "$DU_DELTA" -lt 0 ]; then DU_DELTA=0; fi
if [ "$POOL_DELTA" -lt 0 ]; then POOL_DELTA=0; fi
POOL_DELTA_MB=$(to_mb "$POOL_DELTA")

echo "  du -sm delta:        ${DU_DELTA}MB"
echo "  pool space.used delta: ${POOL_DELTA_MB}MB  ($POOL_DELTA bytes)"
echo "  template du for ref:   ${TPL_DU_MB}MB"
echo ""

# The pool-level delta is the ground truth — it measures actual bytes
# consumed on the backing device.  du may overcount on btrfs because
# it reports referenced (shared) blocks per subvolume.
#
# On a CoW backend, pool delta should be small (metadata only).
# On a dir backend, pool delta ≈ template size (full rsync copy).
THRESHOLD=$((TPL_DU_MB / 5))
if [ "$THRESHOLD" -lt 50 ]; then THRESHOLD=50; fi

echo "--- 6. Assertions ---"
assert_lt "du overhead (${DU_DELTA}MB) under ${THRESHOLD}MB" \
    "$DU_DELTA" "$THRESHOLD"

assert_lt "Pool space.used overhead (${POOL_DELTA_MB}MB) under ${THRESHOLD}MB" \
    "$POOL_DELTA_MB" "$THRESHOLD"

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
