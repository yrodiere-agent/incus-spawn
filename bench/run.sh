#!/bin/bash
# bench/run.sh — Benchmark native image: binary size, memory, proxy throughput
#
# Requires: Oracle GraalVM with native-image, working isx setup (isx init),
#           running Incus daemon
#
# Usage:
#   bench/run.sh                    # full build + benchmark
#   bench/run.sh --skip-build       # reuse existing native binary
#   bench/run.sh --label "baseline" # tag results with a label
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
CACHE_DIR="$SCRIPT_DIR/.cache"
VEGETA_VERSION="12.12.0"
VEGETA_BIN="$CACHE_DIR/vegeta"

SKIP_BUILD=false
LABEL=""

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-build) SKIP_BUILD=true ;;
        --label=*) LABEL="${1#--label=}" ;;
        --label) shift; LABEL="${1:-}" ;;
        --help|-h)
            echo "Usage: bench/run.sh [--skip-build] [--label=NAME]"
            echo ""
            echo "Benchmarks the native image build of the MITM proxy."
            echo "Measures: binary size, startup time, memory (RSS), throughput, latency."
            echo ""
            echo "Options:"
            echo "  --skip-build    Reuse existing native binary in target/"
            echo "  --label=NAME    Tag results with a label (e.g. 'baseline')"
            echo ""
            echo "Requirements:"
            echo "  - Oracle GraalVM with native-image on PATH"
            echo "  - Working isx setup (run 'isx init' first)"
            echo "  - Running Incus daemon"
            exit 0
            ;;
    esac
    shift
done

# ── Helpers ──────────────────────────────────────────────────────────────────

die() { echo "Error: $*" >&2; exit 1; }

cleanup() {
    echo ""
    echo "Cleaning up..."
    [ -n "${PROXY_PID:-}" ] && kill "$PROXY_PID" 2>/dev/null && wait "$PROXY_PID" 2>/dev/null || true
}
trap cleanup EXIT

get_rss_kb() {
    local pid=$1
    awk '/^VmRSS:/ { print $2 }' "/proc/$pid/status" 2>/dev/null || echo "0"
}

epoch_ms() {
    date +%s%3N
}

# ── 1. Validate environment ─────────────────────────────────────────────────

echo "=== Benchmark: native image proxy ==="
echo ""

# Check native-image
if ! command -v native-image &>/dev/null; then
    die "native-image not found on PATH. Install Oracle GraalVM and ensure native-image is available."
fi

GRAALVM_VERSION="$(native-image --version 2>&1 | head -1)"
GRAALVM_FULL="$(native-image --version 2>&1)"
if ! echo "$GRAALVM_FULL" | grep -qi "oracle"; then
    echo "Warning: native-image does not appear to be Oracle GraalVM."
    echo "  Detected: $GRAALVM_VERSION"
    echo "  Release builds use Oracle GraalVM. Results may not be comparable."
    echo ""
fi
echo "GraalVM:  $GRAALVM_VERSION"

# Check isx setup
ISX_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/incus-spawn"
if [ ! -f "$ISX_CONFIG_DIR/config.yaml" ]; then
    die "isx not initialized ($ISX_CONFIG_DIR/config.yaml missing). Run 'isx init' first."
fi
if [ ! -f "$ISX_CONFIG_DIR/ca.key" ]; then
    die "isx CA not initialized ($ISX_CONFIG_DIR/ca.key missing). Run 'isx init' first."
fi

# Resolve gateway IP from Incus bridge
GATEWAY_IP=$(incus network get incusbr0 ipv4.address 2>/dev/null | cut -d/ -f1) || true
if [ -z "$GATEWAY_IP" ]; then
    die "Could not determine Incus bridge gateway IP. Is Incus running?"
fi
echo "Gateway:  $GATEWAY_IP"

GIT_SHA="$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")"
GIT_SUBJECT="$(git -C "$PROJECT_DIR" log -1 --format=%s 2>/dev/null || echo "")"
echo "Git:      $GIT_SHA $GIT_SUBJECT"
echo ""

# ── 2. Build native image ───────────────────────────────────────────────────

RUNNER=$(ls -t "$PROJECT_DIR"/target/incus-spawn-*-runner 2>/dev/null | head -1 || true)

if $SKIP_BUILD; then
    if [ -z "$RUNNER" ]; then
        die "No native binary found in target/. Run without --skip-build first."
    fi
    echo "Skipping build, using existing binary: $RUNNER"
else
    echo "Building native image (this takes a few minutes)..."
    BUILD_START=$(epoch_ms)
    "$PROJECT_DIR/mvnw" -f "$PROJECT_DIR/pom.xml" package -Dnative -DskipTests -q
    BUILD_END=$(epoch_ms)
    BUILD_TIME_MS=$((BUILD_END - BUILD_START))
    RUNNER=$(ls -t "$PROJECT_DIR"/target/incus-spawn-*-runner 2>/dev/null | head -1)
    [ -z "$RUNNER" ] && die "Native build succeeded but no runner binary found in target/"
    echo "Build completed in $((BUILD_TIME_MS / 1000))s"
fi
echo ""

# ── 3. Binary size ──────────────────────────────────────────────────────────

BINARY_SIZE=$(stat -c %s "$RUNNER")
BINARY_SIZE_MB=$(awk "BEGIN { printf \"%.1f\", $BINARY_SIZE / 1048576 }")
echo "Binary size: $BINARY_SIZE_MB MB ($BINARY_SIZE bytes)"

# ── 4. Start proxy and measure startup time ─────────────────────────────────

mkdir -p "$CACHE_DIR"
echo "Starting proxy..."
PROXY_START=$(epoch_ms)
"$RUNNER" proxy start --gateway-ip "$GATEWAY_IP" &>"$CACHE_DIR/proxy.log" &
PROXY_PID=$!

HEALTH_URL="http://$GATEWAY_IP:18080/health"
STARTUP_OK=false
for i in $(seq 1 60); do
    if curl -sf "$HEALTH_URL" &>/dev/null; then
        STARTUP_OK=true
        break
    fi
    if ! kill -0 "$PROXY_PID" 2>/dev/null; then
        echo "Proxy process died. Log tail:"
        tail -20 "$CACHE_DIR/proxy.log"
        die "Proxy failed to start"
    fi
    sleep 0.25
done

if ! $STARTUP_OK; then
    echo "Proxy log tail:"
    tail -20 "$CACHE_DIR/proxy.log"
    die "Proxy health check failed after 15s"
fi

PROXY_READY=$(epoch_ms)
STARTUP_MS=$((PROXY_READY - PROXY_START))
echo "Startup:     ${STARTUP_MS}ms (PID $PROXY_PID)"

# ── 5. Idle RSS ─────────────────────────────────────────────────────────────

sleep 2
IDLE_RSS=$(get_rss_kb "$PROXY_PID")
echo "Idle RSS:    ${IDLE_RSS} KB"

# ── 6. Download vegeta if needed ────────────────────────────────────────────

if [ ! -x "$VEGETA_BIN" ]; then
    echo ""
    echo "Downloading vegeta $VEGETA_VERSION..."
    curl -fsSL "https://github.com/tsenart/vegeta/releases/download/v${VEGETA_VERSION}/vegeta_${VEGETA_VERSION}_linux_amd64.tar.gz" \
        | tar xz -C "$CACHE_DIR" vegeta
    [ -x "$VEGETA_BIN" ] || die "vegeta download failed"
    echo "vegeta $VEGETA_VERSION ready"
fi

# ── 7. Run load test ───────────────────────────────────────────────────────

echo ""
WARMUP_DURATION=3s
STEADY_DURATION=15s
TARGET_RATE=5000
CONNECTIONS=50

echo "Warming up (${WARMUP_DURATION} at ${TARGET_RATE} req/s)..."
echo "GET $HEALTH_URL" | "$VEGETA_BIN" attack \
    -duration="$WARMUP_DURATION" -rate="$TARGET_RATE" -connections="$CONNECTIONS" \
    >/dev/null 2>&1

echo "Running steady-state benchmark (${STEADY_DURATION} at ${TARGET_RATE} req/s)..."
VEGETA_RESULT=$(echo "GET $HEALTH_URL" | "$VEGETA_BIN" attack \
    -duration="$STEADY_DURATION" -rate="$TARGET_RATE" -connections="$CONNECTIONS" \
    | "$VEGETA_BIN" report -type=json 2>&1)

echo "$VEGETA_RESULT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
lat = d.get('latencies', {})
print(f\"  Requests:   {d.get('requests', 0)}\")
print(f\"  Rate:       {d.get('rate', 0):.1f} req/s\")
print(f\"  Throughput: {d.get('throughput', 0):.1f} req/s\")
print(f\"  Success:    {d.get('success', 0)*100:.1f}%\")
print(f\"  Latency p50: {lat.get('50th', 0)/1000:.1f} us\")
print(f\"  Latency p99: {lat.get('99th', 0)/1000:.1f} us\")
print(f\"  Latency max: {lat.get('max', 0)/1000:.1f} us\")
"

# ── 8. Peak RSS ─────────────────────────────────────────────────────────────

PEAK_RSS=$(get_rss_kb "$PROXY_PID")
echo ""
echo "Peak RSS:    ${PEAK_RSS} KB"

# ── 9. Stop proxy ──────────────────────────────────────────────────────────

kill "$PROXY_PID" 2>/dev/null; wait "$PROXY_PID" 2>/dev/null || true
PROXY_PID=""

# ── 10. Parse vegeta stats ──────────────────────────────────────────────────

# vegeta JSON report has latencies in nanoseconds
THROUGHPUT_DATA=$(echo "$VEGETA_RESULT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
lat = d.get('latencies', {})
print(json.dumps({
    'requestCount': d.get('requests', 0),
    'meanReqPerSec': round(d.get('throughput', 0), 1),
    'p50Us': round(lat.get('50th', 0) / 1000.0, 1),
    'p99Us': round(lat.get('99th', 0) / 1000.0, 1),
    'p999Us': round(lat.get('max', 0) / 1000.0, 1),
}))
" 2>/dev/null) || THROUGHPUT_DATA='{"requestCount":0,"meanReqPerSec":0,"p50Us":0,"p99Us":0,"p999Us":0}'

# ── 11. Save results ────────────────────────────────────────────────────────

mkdir -p "$RESULTS_DIR"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
RESULT_FILE="$RESULTS_DIR/${GIT_SHA}-$(date +%Y%m%d-%H%M%S).json"

python3 -c "
import json, sys
throughput = json.loads('''$THROUGHPUT_DATA''')
result = {
    'label': '''$LABEL''',
    'timestamp': '$TIMESTAMP',
    'gitSha': '$GIT_SHA',
    'gitSubject': '''$GIT_SUBJECT''',
    'graalvm': '''$GRAALVM_VERSION''',
    'binarySizeBytes': $BINARY_SIZE,
    'startupMs': $STARTUP_MS,
    'idleRssKb': $IDLE_RSS,
    'peakRssKb': $PEAK_RSS,
    'throughput': throughput,
    'loadTool': 'vegeta',
    'vegetaConfig': {
        'connections': $CONNECTIONS,
        'duration': '$STEADY_DURATION',
        'targetRate': $TARGET_RATE,
    },
}
with open('$RESULT_FILE', 'w') as f:
    json.dump(result, f, indent=2)
    f.write('\n')
print(json.dumps(result, indent=2))
" || die "Failed to write results"

echo ""
echo "Results saved to: $RESULT_FILE"

# ── 12. Summary and comparison ──────────────────────────────────────────────

echo ""
echo "=== Results ==="
printf "%-20s %s\n" "Binary size:" "$BINARY_SIZE_MB MB"
printf "%-20s %s\n" "Startup time:" "${STARTUP_MS} ms"
printf "%-20s %s\n" "Idle RSS:" "${IDLE_RSS} KB"
printf "%-20s %s\n" "Peak RSS:" "${PEAK_RSS} KB"

REQ_PER_SEC=$(echo "$THROUGHPUT_DATA" | python3 -c "import sys,json; print(json.load(sys.stdin)['meanReqPerSec'])")
P50=$(echo "$THROUGHPUT_DATA" | python3 -c "import sys,json; print(json.load(sys.stdin)['p50Us'])")
P99=$(echo "$THROUGHPUT_DATA" | python3 -c "import sys,json; print(json.load(sys.stdin)['p99Us'])")
P999=$(echo "$THROUGHPUT_DATA" | python3 -c "import sys,json; print(json.load(sys.stdin)['p999Us'])")

printf "%-20s %s\n" "Throughput:" "${REQ_PER_SEC} req/s"
printf "%-20s %s\n" "Latency p50:" "${P50} us"
printf "%-20s %s\n" "Latency p99:" "${P99} us"
printf "%-20s %s\n" "Latency p99.9:" "${P999} us"

# Compare with most recent previous result
PREV_RESULT=$(ls -t "$RESULTS_DIR"/*.json 2>/dev/null | grep -v "$(basename "$RESULT_FILE")" | head -1 || true)
if [ -n "$PREV_RESULT" ]; then
    echo ""
    echo "=== Comparison with previous run ==="
    PREV_LABEL=$(python3 -c "import json; d=json.load(open('$PREV_RESULT')); print(d.get('label','') or d.get('gitSha',''))")
    echo "Previous: $PREV_LABEL ($(basename "$PREV_RESULT"))"
    echo ""

    python3 -c "
import json

with open('$RESULT_FILE') as f:
    curr = json.load(f)
with open('$PREV_RESULT') as f:
    prev = json.load(f)

def delta(name, curr_val, prev_val, unit, lower_is_better=True):
    if prev_val == 0:
        print(f'  {name:<20s} {curr_val:>12} {unit}  (no previous)')
        return
    diff = curr_val - prev_val
    pct = (diff / prev_val) * 100
    sign = '+' if diff >= 0 else ''
    indicator = ''
    if abs(pct) >= 1:
        if lower_is_better:
            indicator = ' !!!' if diff > 0 else ' (better)'
        else:
            indicator = ' (better)' if diff > 0 else ' !!!'
    print(f'  {name:<20s} {curr_val:>12} {unit}  ({sign}{pct:.1f}%{indicator})')

ct = curr.get('throughput', {})
pt = prev.get('throughput', {})

delta('Binary size', curr['binarySizeBytes'], prev['binarySizeBytes'], 'B')
delta('Startup time', curr['startupMs'], prev['startupMs'], 'ms')
delta('Idle RSS', curr['idleRssKb'], prev['idleRssKb'], 'KB')
delta('Peak RSS', curr['peakRssKb'], prev['peakRssKb'], 'KB')
delta('Throughput', ct.get('meanReqPerSec',0), pt.get('meanReqPerSec',0), 'req/s', lower_is_better=False)
delta('Latency p50', ct.get('p50Us',0), pt.get('p50Us',0), 'us')
delta('Latency p99', ct.get('p99Us',0), pt.get('p99Us',0), 'us')
delta('Latency p99.9', ct.get('p999Us',0), pt.get('p999Us',0), 'us')
"
fi

echo ""
echo "Done."
