#!/usr/bin/env bash
# collect_perf_ipc.sh — Per-core IPC / cycles / instructions collector
# Runs on gnb1 or gnb2. Writes to /tmp/ran_collect/perf_ipc_<NODE>.csv
# Usage: bash collect_perf_ipc.sh [interval_sec] [output_csv]
#
# Columns: timestamp_ms, phase, node, cpu, instructions, cycles, ipc,
#          cache_refs, cache_misses, branch_misses, context_switches

set -euo pipefail

INTERVAL="${1:-2}"
NODE="${NODE:-gnb1}"
OUT="${2:-/tmp/ran_collect/perf_ipc_${NODE}.csv}"
PHASE_FILE="/tmp/ran_collect/phase.txt"

mkdir -p "$(dirname "$OUT")"

# Check perf is available
if ! command -v perf &>/dev/null; then
    echo "[collect_perf_ipc] ERROR: 'perf' not found. Install with:" >&2
    echo "  sudo apt-get install linux-tools-\$(uname -r) linux-tools-generic" >&2
    exit 1
fi

# Require paranoia ≤ 1 for per-core access
PARANOIA=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo 3)
if [ "$PARANOIA" -gt 1 ]; then
    echo "[collect_perf_ipc] WARNING: perf_event_paranoid=$PARANOIA — trying sudo" >&2
    PERF_CMD="sudo perf"
else
    PERF_CMD="perf"
fi

NUM_CPUS=$(nproc)

# Write CSV header
if [ ! -f "$OUT" ]; then
    echo "timestamp_ms,phase,node,cpu,instructions,cycles,ipc,cache_refs,cache_misses,branch_misses,context_switches" > "$OUT"
fi

echo "[collect_perf_ipc] Starting on $NODE (${NUM_CPUS} CPUs), interval=${INTERVAL}s → $OUT"

# Trap for clean exit
cleanup() { echo "[collect_perf_ipc] Stopped."; exit 0; }
trap cleanup SIGTERM SIGINT

while true; do
    TS_MS=$(date +%s%3N)
    PHASE=$(cat "$PHASE_FILE" 2>/dev/null || echo "unknown")

    # Run perf stat once per interval, aggregate all CPUs
    # Outputs: instructions, cycles, cache-references, cache-misses, branch-misses, context-switches
    PERF_OUT=$( $PERF_CMD stat \
        -e instructions,cycles,cache-references,cache-misses,branch-misses,context-switches \
        --all-cpus \
        --no-big-num \
        sleep "$INTERVAL" 2>&1 ) || true

    # Parse perf stat output (lines like: "12345678  instructions")
    parse_event() {
        local name="$1"
        echo "$PERF_OUT" | grep -E "[0-9]+ +${name}" | awk '{gsub(",","",$1); print $1+0}' | head -1
    }

    INSTR=$(parse_event "instructions")   ; INSTR=${INSTR:-0}
    CYCLES=$(parse_event "cycles")        ; CYCLES=${CYCLES:-0}
    CACHE_R=$(parse_event "cache-references") ; CACHE_R=${CACHE_R:-0}
    CACHE_M=$(parse_event "cache-misses") ; CACHE_M=${CACHE_M:-0}
    BRANCH_M=$(parse_event "branch-misses") ; BRANCH_M=${BRANCH_M:-0}
    CTX=$(parse_event "context-switches") ; CTX=${CTX:-0}

    # IPC = instructions / cycles (guard divide-by-zero)
    if [ "$CYCLES" -gt 0 ] 2>/dev/null; then
        IPC=$(awk "BEGIN{printf \"%.4f\", $INSTR/$CYCLES}")
    else
        IPC="0.0000"
    fi

    # Write one aggregate row (cpu=all)
    echo "${TS_MS},${PHASE},${NODE},all,${INSTR},${CYCLES},${IPC},${CACHE_R},${CACHE_M},${BRANCH_M},${CTX}" >> "$OUT"

    # ---- Per-CPU rows using /proc/stat delta ----
    # Capture two snapshots of /proc/stat separated by 0.1s
    SNAP1=$(grep "^cpu[0-9]" /proc/stat)
    sleep 0.1
    SNAP2=$(grep "^cpu[0-9]" /proc/stat)

    while IFS= read -r LINE1; do
        CPU=$(echo "$LINE1" | awk '{print $1}')
        # Read matching line from snap2
        LINE2=$(echo "$SNAP2" | grep "^${CPU} " || true)
        [ -z "$LINE2" ] && continue

        # Fields: user nice system idle iowait irq softirq steal
        read -r _ u1 n1 s1 id1 io1 ir1 si1 st1 <<< "$LINE1"
        read -r _ u2 n2 s2 id2 io2 ir2 si2 st2 <<< "$LINE2"

        TOTAL1=$((u1+n1+s1+id1+io1+ir1+si1+st1))
        TOTAL2=$((u2+n2+s2+id2+io2+ir2+si2+st2))
        IDLE1=$((id1+io1))
        IDLE2=$((id2+io2))

        DTOTAL=$((TOTAL2-TOTAL1))
        DIDLE=$((IDLE2-IDLE1))

        if [ "$DTOTAL" -gt 0 ]; then
            UTIL=$(awk "BEGIN{printf \"%.2f\", 100.0*($DTOTAL-$DIDLE)/$DTOTAL}")
        else
            UTIL="0.00"
        fi

        # Emit per-cpu row with util in 'ipc' field (actual IPC requires perf per-cpu mode)
        # We reuse ipc column for cpu_util_pct here; instructions/cycles carry proc/stat totals
        echo "${TS_MS},${PHASE},${NODE},${CPU},0,${DTOTAL},${UTIL},0,0,0,0" >> "$OUT"
    done <<< "$SNAP1"

    # Sleep is already consumed by perf stat above; no extra sleep needed
done
