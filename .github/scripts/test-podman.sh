#!/bin/bash
# Tests rootless podman inside an incus-spawn container.
# Validates subordinate UID/GID support (security.idmap.size + subuid/subgid)
# by running a PostgreSQL container as agentuser without root privileges.
#
# Usage: incus file push test-podman.sh <instance>/tmp/
#        incus exec <instance> -- bash /tmp/test-podman.sh

set -euo pipefail

PASS=0
FAIL=0
ERRORS=""

assert_eq() {
    local desc="$1" expected="$2"; shift 2
    local actual
    actual=$("$@" 2>/dev/null) || true
    if [ "$actual" = "$expected" ]; then
        printf '  \033[32mPASS\033[0m  %s\n' "$desc"
        PASS=$((PASS + 1))
    else
        printf '  \033[31mFAIL\033[0m  %s  (expected: %s, got: %s)\n' "$desc" "$expected" "$actual"
        FAIL=$((FAIL + 1))
        ERRORS="${ERRORS}  - ${desc} (expected '${expected}', got '${actual}')\n"
    fi
}

echo "========================================"
echo " Rootless podman integration test"
echo "========================================"
echo ""

echo "[1] Rootless PostgreSQL via podman"

# Run PostgreSQL as agentuser (rootless podman).
# This requires working subordinate UID/GID mappings:
# - security.idmap.size must cover the subordinate range
# - /etc/subuid and /etc/subgid must have entries for agentuser
echo "  Starting PostgreSQL container as agentuser (rootless)..."
su -l agentuser -c '
    podman run -d --name test-pg \
        -e POSTGRES_PASSWORD=testpass \
        -p 15432:5432 \
        docker.io/library/postgres:17-alpine
'

echo "  Waiting for PostgreSQL to be ready..."
for i in $(seq 1 30); do
    if su -l agentuser -c "podman exec test-pg pg_isready -U postgres" >/dev/null 2>&1; then
        echo "  PostgreSQL ready after ${i}s"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "  PostgreSQL did not become ready within 30s"
        su -l agentuser -c "podman logs test-pg" 2>&1 | tail -20
        exit 1
    fi
    sleep 1
done

assert_eq "SELECT 1 returns 1" "1" \
    su -l agentuser -c "podman exec test-pg psql -U postgres -tAc 'SELECT 1'"

echo ""
echo "  Cleaning up..."
su -l agentuser -c "podman rm -f test-pg" >/dev/null 2>&1

echo ""
echo "========================================"
TOTAL=$((PASS + FAIL))
printf " Results: \033[1m%d/%d passed\033[0m" "$PASS" "$TOTAL"
if [ "$FAIL" -gt 0 ]; then
    printf ", \033[31m%d failed\033[0m" "$FAIL"
fi
echo ""
echo "========================================"

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "Failed tests:"
    printf "$ERRORS"
    exit 1
fi
