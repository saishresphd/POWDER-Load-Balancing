#!/usr/bin/env bash
# collect_ue51_handover.sh
# Logs UE51 handover transition from gNB1 → gNB2 at 500ms resolution.
# Runs on: uehost2 (pc801, 10.10.1.5) — where UE51 lives.
# Output: /tmp/ran_collect/ue51_handover.csv
#         /tmp/ran_collect/ue51_handover_summary.txt
# Usage: bash collect_ue51_handover.sh [interval_ms] [duration_s]

set -euo pipefail

INTERVAL_MS="${1:-500}"
DURATION_S="${2:-300}"
GNB1="10.10.1.2"
GNB2="10.10.1.3"
OUTDIR="/tmp/ran_collect"
OUTFILE="$OUTDIR/ue51_handover.csv"
SUMMARY="$OUTDIR/ue51_handover_summary.txt"
PHASE_FILE="$OUTDIR/phase.txt"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=3 -o BatchMode=yes"
RAPL_PATH="/sys/class/powercap/intel-rapl:0/energy_uj"

mkdir -p "$OUTDIR"

echo "timestamp_ms,gnb1_nof_ue,gnb2_nof_ue,ue51_tun_active,cpu_pct,mem_used_mb,power_w,phase,event_note" \
    > "$OUTFILE"

read_phase() { cat "$PHASE_FILE" 2>/dev/null || echo "unknown"; }
log()        { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Query nof_ue from a gNB's live srsenb CSV log
query_nof_ue() {
    local host="$1"
    local gnb_id="$2"
    # srsenb appends semicolon-delimited rows to /tmp/ran_collect/gnb_metrics_raw.csv
    # field 2 (0-indexed) = nof_ue
    ssh $SSH_OPTS saish@"$host" \
        "tail -1 /tmp/ran_collect/gnb_metrics_raw_${gnb_id}.csv 2>/dev/null | cut -d';' -f2 || echo '?'" \
        2>/dev/null || echo "?"
}

# Check if ue51 tun/netns is up (tun device exists inside netns)
ue51_tun_active() {
    ip netns exec ue51 ip link show tun_srsue 2>/dev/null | grep -c "UP" || echo "0"
}

# Read RAPL package power (1 sample window = INTERVAL_MS)
read_power() {
    if [ -r "$RAPL_PATH" ]; then
        local e1 e2
        e1=$(cat "$RAPL_PATH")
        sleep 0.1
        e2=$(cat "$RAPL_PATH")
        local delta=$(( e2 - e1 ))
        # energy in uJ over 0.1s → Watts
        python3 -c "print(f'{$delta / 1e6 / 0.1:.2f}')" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# Read CPU % (1s sample via /proc/stat)
read_cpu_pct() {
    local s1 s2
    s1=$(grep '^cpu ' /proc/stat)
    sleep 0.2
    s2=$(grep '^cpu ' /proc/stat)
    python3 -c "
s1 = list(map(int, '$s1'.split()[1:]))
s2 = list(map(int, '$s2'.split()[1:]))
idle1 = s1[3] + s1[4]
idle2 = s2[3] + s2[4]
tot1  = sum(s1)
tot2  = sum(s2)
dt    = tot2 - tot1
di    = idle2 - idle1
cpu   = 100.0 * (dt - di) / dt if dt else 0
print(f'{cpu:.1f}')
" 2>/dev/null || echo "0"
}

# Read used memory in MB
read_mem_mb() {
    local total free buffers cached
    total=$(grep '^MemTotal:'  /proc/meminfo | awk '{print $2}')
    free=$(grep  '^MemFree:'   /proc/meminfo | awk '{print $2}')
    buffers=$(grep '^Buffers:' /proc/meminfo | awk '{print $2}')
    cached=$(grep  '^Cached:'  /proc/meminfo | head -1 | awk '{print $2}')
    python3 -c "print(int(($total - $free - $buffers - $cached) / 1024))" 2>/dev/null || echo "0"
}

# --- State tracking ---
detach_ts_ms=""
attach_ts_ms=""
prev_tun=0
prev_gnb1_ue="?"
prev_gnb2_ue="?"
sample_count=0
max_samples=$(( DURATION_S * 1000 / INTERVAL_MS ))
sleep_s=$(python3 -c "print($INTERVAL_MS / 1000)")

log "=== UE51 handover monitor start: ${INTERVAL_MS}ms interval, ${DURATION_S}s duration ==="
log "Output: $OUTFILE"

while (( sample_count < max_samples )); do
    ts_ms=$(date '+%s%3N')
    phase=$(read_phase)

    # Collect metrics in parallel to minimise latency
    gnb1_nof_ue=$(query_nof_ue "$GNB1" "gnb1" &)
    gnb2_nof_ue=$(query_nof_ue "$GNB2" "gnb2" &)
    wait
    gnb1_nof_ue=$(query_nof_ue "$GNB1" "gnb1")
    gnb2_nof_ue=$(query_nof_ue "$GNB2" "gnb2")

    tun_active=$(ue51_tun_active)
    cpu_pct=$(read_cpu_pct)
    mem_mb=$(read_mem_mb)
    power_w=$(read_power)

    # Detect events
    event_note=""

    # Detach: tun was active, now gone
    if (( prev_tun == 1 )) && (( tun_active == 0 )); then
        detach_ts_ms="$ts_ms"
        event_note="UE51_DETACH_FROM_GNB1"
        log "*** UE51 DETACH from gNB1 at ${ts_ms}ms ***"
    fi

    # Reattach: tun was gone, now active
    if (( prev_tun == 0 )) && (( tun_active == 1 )); then
        attach_ts_ms="$ts_ms"
        event_note="UE51_ATTACH_TO_GNB2"
        log "*** UE51 ATTACH to gNB2 at ${ts_ms}ms ***"

        # Write handover summary immediately
        if [ -n "$detach_ts_ms" ]; then
            ho_duration_ms=$(( attach_ts_ms - detach_ts_ms ))
            {
                echo "=== UE51 Handover Summary ==="
                echo "Detach timestamp (ms): $detach_ts_ms"
                echo "Attach timestamp (ms): $attach_ts_ms"
                echo "Handover duration (ms): $ho_duration_ms"
                echo "gNB1 UE count at detach: $prev_gnb1_ue"
                echo "gNB2 UE count at attach: $gnb2_nof_ue"
                echo "CPU % at attach: $cpu_pct"
                echo "Memory used (MB) at attach: $mem_mb"
                echo "Power (W) at attach: $power_w"
                echo "Phase at attach: $phase"
            } > "$SUMMARY"
            log "Handover duration: ${ho_duration_ms} ms"
        fi
    fi

    echo "${ts_ms},${gnb1_nof_ue},${gnb2_nof_ue},${tun_active},${cpu_pct},${mem_mb},${power_w},${phase},${event_note}" \
        >> "$OUTFILE"

    prev_tun=$tun_active
    prev_gnb1_ue="$gnb1_nof_ue"
    prev_gnb2_ue="$gnb2_nof_ue"

    (( sample_count++ )) || true

    # Break early if collection_complete phase is set
    [ "$phase" = "collection_complete" ] && break

    sleep "$sleep_s"
done

log "=== UE51 handover monitor complete. Samples: $sample_count ==="
log "CSV: $OUTFILE"
[ -f "$SUMMARY" ] && log "Summary: $SUMMARY"
