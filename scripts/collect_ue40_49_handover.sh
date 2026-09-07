#!/usr/bin/env bash
# collect_ue40_49_handover.sh
# ============================================================
# Monitors the 9-UE batch handover of UE40-49 from gNB1 → gNB2.
# Runs on: uehost1 (pc808, 10.10.1.4) — where UE40-49 processes live.
#
# Tracks per-UE tun device state at INTERVAL_MS resolution.
# Captures:
#   - Per-UE detach timestamp (tun_srsueN goes DOWN)
#   - Per-UE re-attach timestamp (tun_srsueN comes UP on gNB2)
#   - System CPU/mem/power during handover window
#   - gNB1/gNB2 nof_ue counts polled remotely every sample
#
# Output:
#   /tmp/ran_collect/ue40_49_handover.csv      — per-sample per-UE state
#   /tmp/ran_collect/ue40_49_handover_summary.txt
#
# Usage: bash collect_ue40_49_handover.sh [interval_ms] [duration_s]
# ============================================================
set -euo pipefail

INTERVAL_MS="${1:-500}"
DURATION_S="${2:-600}"
UE_START=40
UE_END=49
GNB1="10.10.1.2"
GNB2="10.10.1.3"
OUTDIR="/tmp/ran_collect"
OUTFILE="$OUTDIR/ue40_49_handover.csv"
SUMMARY="$OUTDIR/ue40_49_handover_summary.txt"
PHASE_FILE="$OUTDIR/phase.txt"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=3 -o BatchMode=yes"
RAPL_PATH="/sys/class/powercap/intel-rapl:0/energy_uj"

mkdir -p "$OUTDIR"

# ── CSV header ───────────────────────────────────────────────
{
  echo -n "timestamp_ms,gnb1_nof_ue,gnb2_nof_ue,cpu_pct,mem_used_mb,power_w,phase,event_note"
  for i in $(seq $UE_START $UE_END); do
    echo -n ",ue${i}_tun_active"
  done
  echo ""
} > "$OUTFILE"

read_phase() { cat "$PHASE_FILE" 2>/dev/null || echo "unknown"; }
log()        { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# ── Query nof_ue from a remote gNB's live CSV ────────────────
query_nof_ue() {
    local host="$1" gnb_id="$2"
    ssh $SSH_OPTS saish@"$host" \
        "tail -1 /tmp/ran_collect/gnb_metrics_raw_${gnb_id}.csv 2>/dev/null | cut -d';' -f2 || echo '?'" \
        2>/dev/null || echo "?"
}

# ── Check tun device state per UE (in local netns) ──────────
ue_tun_active() {
    local ue_id="$1"
    ip netns exec ue${ue_id} ip link show tun_srsue${ue_id} 2>/dev/null | grep -c "UP" || echo "0"
}

# ── RAPL power (100ms window) ────────────────────────────────
read_power() {
    if [ -r "$RAPL_PATH" ]; then
        local e1 e2
        e1=$(cat "$RAPL_PATH")
        sleep 0.1
        e2=$(cat "$RAPL_PATH")
        python3 -c "print(f'{($e2 - $e1) / 1e6 / 0.1:.2f}')" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# ── CPU % (200ms sample) ─────────────────────────────────────
read_cpu_pct() {
    local s1 s2
    s1=$(grep '^cpu ' /proc/stat)
    sleep 0.2
    s2=$(grep '^cpu ' /proc/stat)
    python3 -c "
s1 = list(map(int, '$s1'.split()[1:]))
s2 = list(map(int, '$s2'.split()[1:]))
idle1 = s1[3]+s1[4]; idle2 = s2[3]+s2[4]
tot1 = sum(s1);      tot2 = sum(s2)
dt = tot2 - tot1;    di = idle2 - idle1
cpu = 100.0*(dt-di)/dt if dt else 0
print(f'{cpu:.1f}')
" 2>/dev/null || echo "0"
}

# ── Memory used (MB) ─────────────────────────────────────────
read_mem_mb() {
    local total free buf cached
    total=$(  awk '/MemTotal:/  {print $2}' /proc/meminfo)
    free=$(   awk '/MemFree:/   {print $2}' /proc/meminfo)
    buf=$(    awk '/Buffers:/   {print $2}' /proc/meminfo)
    cached=$( awk '/^Cached:/   {print $2}' /proc/meminfo | head -1)
    python3 -c "print(int(($total-$free-$buf-$cached)/1024))" 2>/dev/null || echo "0"
}

# ── Per-UE state tracking ────────────────────────────────────
declare -A PREV_TUN       # prev tun state per UE
declare -A DETACH_TS      # detach timestamp per UE (ms)
declare -A ATTACH_TS      # attach timestamp per UE (ms)
declare -A HANDOVER_MS    # handover duration per UE (ms)

for i in $(seq $UE_START $UE_END); do
    PREV_TUN[$i]=0
    DETACH_TS[$i]=""
    ATTACH_TS[$i]=""
    HANDOVER_MS[$i]=""
done

sleep_s=$(python3 -c "print($INTERVAL_MS / 1000)")
max_samples=$(( DURATION_S * 1000 / INTERVAL_MS ))
sample_count=0
lb_trigger_ts=""
all_migrated=0

log "=== UE40-49 multi-UE handover monitor start ==="
log "Interval=${INTERVAL_MS}ms  Duration=${DURATION_S}s  Output=${OUTFILE}"

while (( sample_count < max_samples )); do
    ts_ms=$(date '+%s%3N')
    phase=$(read_phase)

    # Remote gNB UE counts (parallel SSH)
    gnb1_nof_ue=$(query_nof_ue "$GNB1" "gnb1")
    gnb2_nof_ue=$(query_nof_ue "$GNB2" "gnb2")

    cpu_pct=$(read_cpu_pct)
    mem_mb=$(read_mem_mb)
    power_w=$(read_power)

    # Capture lb_trigger timestamp from file
    if [ -z "$lb_trigger_ts" ] && [ -f "$OUTDIR/lb_trigger_9ue.txt" ]; then
        lb_trigger_ts=$(grep 'lb_trigger_ts_ms' "$OUTDIR/lb_trigger_9ue.txt" | cut -d= -f2)
    fi

    # Build per-UE tun state columns + detect events
    tun_cols=""
    event_note=""
    newly_detached=""
    newly_attached=""

    for i in $(seq $UE_START $UE_END); do
        tun=$(ue_tun_active "$i")
        prev=${PREV_TUN[$i]}

        if (( prev == 1 )) && (( tun == 0 )); then
            DETACH_TS[$i]="$ts_ms"
            newly_detached="${newly_detached}UE${i}_DETACH "
            log "*** UE${i} DETACH from gNB1 at ${ts_ms}ms ***"
        fi
        if (( prev == 0 )) && (( tun == 1 )); then
            ATTACH_TS[$i]="$ts_ms"
            if [ -n "${DETACH_TS[$i]}" ]; then
                HANDOVER_MS[$i]=$(( ts_ms - ${DETACH_TS[$i]} ))
                log "*** UE${i} ATTACH to gNB2 at ${ts_ms}ms  HO=${HANDOVER_MS[$i]}ms ***"
            fi
            newly_attached="${newly_attached}UE${i}_ATTACH "
        fi

        PREV_TUN[$i]=$tun
        tun_cols="${tun_cols},${tun}"
    done

    [ -n "$newly_detached" ] && event_note="${event_note}${newly_detached}"
    [ -n "$newly_attached" ] && event_note="${event_note}${newly_attached}"
    event_note="${event_note// /_}"
    event_note="${event_note%_}"

    echo "${ts_ms},${gnb1_nof_ue},${gnb2_nof_ue},${cpu_pct},${mem_mb},${power_w},${phase},${event_note}${tun_cols}" \
        >> "$OUTFILE"

    # Check if all UEs have completed migration
    migrated_count=0
    for i in $(seq $UE_START $UE_END); do
        [ -n "${ATTACH_TS[$i]}" ] && (( migrated_count++ ))
    done
    if (( migrated_count == (UE_END - UE_START + 1) )) && (( all_migrated == 0 )); then
        all_migrated=1
        log "=== ALL UEs (${UE_START}-${UE_END}) migrated to gNB2 ==="

        # Write summary immediately
        {
            echo "=== UE40-49 Batch Handover Summary ==="
            echo "LB trigger ts (ms)  : ${lb_trigger_ts:-unknown}"
            echo "gNB1 nof_ue at end  : ${gnb1_nof_ue}"
            echo "gNB2 nof_ue at end  : ${gnb2_nof_ue}"
            echo ""
            echo "Per-UE handover latencies:"
            total_ho=0; n_ho=0
            for i in $(seq $UE_START $UE_END); do
                ho="${HANDOVER_MS[$i]:-N/A}"
                detach="${DETACH_TS[$i]:-N/A}"
                attach="${ATTACH_TS[$i]:-N/A}"
                echo "  UE${i}: detach=${detach}ms  attach=${attach}ms  HO_duration=${ho}ms"
                if [ "$ho" != "N/A" ]; then
                    total_ho=$(( total_ho + ho ))
                    (( n_ho++ ))
                fi
            done
            echo ""
            if (( n_ho > 0 )); then
                avg_ho=$(python3 -c "print(f'{$total_ho / $n_ho:.1f}')")
                echo "Average handover latency : ${avg_ho} ms"
                echo "N successful handovers   : ${n_ho}"
            fi
            echo ""
            echo "── Paper Equations (from IEEE 10949489) ──────────────────"
            echo "Eq.3: Ptotal = Pbase + NaU·PaU + NUi·PUi"
            echo "  → Collect pre-LB and post-LB power_w values from"
            echo "     /tmp/ran_collect/power_gnb1.csv and power_gnb2.csv"
            echo "  → NaU (active UEs) changes from 49 → 40 on gNB1"
            echo "  → NaU changes from 0 → 9 on gNB2"
            echo ""
            echo "Eq.4: Psaved = Pactive - Pswitched"
            echo "  → Psaved = power(gNB1 with 49 UEs) - power(gNB1 with 40 UEs)"
            echo "  → Marginal cost on gNB2 = power(gNB2 with 9 UEs) - Pbase_gnb2"
            echo ""
            echo "Key Finding 3 extension: NC UE savings on gNB1"
            echo "  → 9 UEs moved off gNB1; compare sys_load delta in gnb_metrics.csv"
            echo ""
        } > "$SUMMARY"
        log "Summary written: $SUMMARY"
    fi

    (( sample_count++ )) || true
    [ "$phase" = "collection_complete" ] && break
    sleep "$sleep_s"
done

log "=== UE40-49 handover monitor complete. Samples: $sample_count ==="
log "CSV: $OUTFILE"
[ -f "$SUMMARY" ] && log "Summary: $SUMMARY"
