#!/usr/bin/env bash
# run_iperf_500mbps.sh
# Ramp iperf3 traffic from 20 Mbps → 500 Mbps across all UEs (1-51).
# Runs on uehost1; UE51 is on uehost2 and is handled via SSH.
# Output: /tmp/ran_collect/iperf_results_500.csv
# Usage: bash run_iperf_500mbps.sh [ue_count] [duration_per_step_s]

set -euo pipefail

UE_COUNT="${1:-51}"
STEP_DURATION="${2:-15}"
IPERF_SERVER="10.45.0.1"
OUTDIR="/tmp/ran_collect"
OUTFILE="$OUTDIR/iperf_results_500.csv"
PHASE_FILE="$OUTDIR/phase.txt"
UEHOST2="10.10.1.5"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5"
BATCH=5

mkdir -p "$OUTDIR"

# Write CSV header if file does not exist
if [ ! -f "$OUTFILE" ]; then
    echo "timestamp,ue_id,direction,target_mbps,actual_mbps,bytes,duration_s,retransmits,phase" > "$OUTFILE"
fi

read_phase() {
    cat "$PHASE_FILE" 2>/dev/null || echo "unknown"
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# iperf3 for a single UE in its netns; appends one row to OUTFILE
run_ue_iperf() {
    local ue_id="$1"
    local target_mbps="$2"
    local direction="$3"   # dl or ul
    local phase
    phase=$(read_phase)
    local port=$((5200 + ue_id))
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')

    local dir_flag=""
    [ "$direction" = "ul" ] && dir_flag="-R"

    # Run iperf3 inside the UE network namespace
    local result
    result=$(ip netns exec "ue${ue_id}" iperf3 -c "$IPERF_SERVER" \
        -b "${target_mbps}M" -t "$STEP_DURATION" \
        -p "$port" $dir_flag \
        --json 2>/dev/null || echo "{}")

    local actual_mbps bytes retransmits
    actual_mbps=$(echo "$result" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    bps = d['end']['sum_sent']['bits_per_second']
    print(f'{bps/1e6:.3f}')
except Exception:
    print('0')
" 2>/dev/null || echo "0")

    bytes=$(echo "$result" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d['end']['sum_sent']['bytes'])
except Exception:
    print('0')
" 2>/dev/null || echo "0")

    retransmits=$(echo "$result" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d['end']['sum_sent'].get('retransmits', 0))
except Exception:
    print('0')
" 2>/dev/null || echo "0")

    echo "$ts,$ue_id,$direction,$target_mbps,$actual_mbps,$bytes,$STEP_DURATION,$retransmits,$phase" >> "$OUTFILE"
    log "  UE$ue_id $direction ${target_mbps}Mbps → actual ${actual_mbps}Mbps retx=$retransmits"
}

# Same but via SSH to uehost2 for UE51
run_ue51_iperf_remote() {
    local target_mbps="$1"
    local direction="$2"
    local phase
    phase=$(read_phase)
    local port=5251
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')

    local dir_flag=""
    [ "$direction" = "ul" ] && dir_flag="-R"

    local result
    result=$(ssh $SSH_OPTS saish@"$UEHOST2" \
        "ip netns exec ue51 iperf3 -c $IPERF_SERVER -b ${target_mbps}M \
         -t $STEP_DURATION -p $port $dir_flag --json 2>/dev/null || echo '{}'" )

    local actual_mbps bytes retransmits
    actual_mbps=$(echo "$result" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    bps = d['end']['sum_sent']['bits_per_second']
    print(f'{bps/1e6:.3f}')
except Exception:
    print('0')
" 2>/dev/null || echo "0")

    bytes=$(echo "$result" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d['end']['sum_sent']['bytes'])
except Exception:
    print('0')
" 2>/dev/null || echo "0")

    retransmits=$(echo "$result" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d['end']['sum_sent'].get('retransmits', 0))
except Exception:
    print('0')
" 2>/dev/null || echo "0")

    echo "$ts,51,$direction,$target_mbps,$actual_mbps,$bytes,$STEP_DURATION,$retransmits,$phase" >> "$OUTFILE"
    log "  UE51(remote) $direction ${target_mbps}Mbps → actual ${actual_mbps}Mbps retx=$retransmits"
}

# Ramp schedule: step_mbps values
RAMP_STEPS=(20 30 50 75 100 150 200 250 300 350 400 450 500)

log "=== iperf 500 Mbps ramp start: $UE_COUNT UEs, ${STEP_DURATION}s/step ==="
log "Output: $OUTFILE"

for target in "${RAMP_STEPS[@]}"; do
    log "--- Ramp step: ${target} Mbps ---"

    # Launch batches of BATCH UEs (1..50) in parallel
    batch_pids=()
    for (( ue=1; ue<=50 && ue<=UE_COUNT; ue++ )); do
        run_ue_iperf "$ue" "$target" "dl" &
        batch_pids+=($!)
        if (( ${#batch_pids[@]} >= BATCH )); then
            wait "${batch_pids[@]}"
            batch_pids=()
        fi
    done
    # Wait for any remaining batch
    [ ${#batch_pids[@]} -gt 0 ] && wait "${batch_pids[@]}"

    # UE51 (on uehost2) — only if requested
    if (( UE_COUNT >= 51 )); then
        run_ue51_iperf_remote "$target" "dl"
    fi

    log "--- Step ${target} Mbps complete ---"
done

log "=== iperf 500 Mbps ramp COMPLETE ==="
log "Results: $OUTFILE"
