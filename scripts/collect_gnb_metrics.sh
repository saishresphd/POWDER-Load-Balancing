#!/bin/bash
# ============================================================
# collect_gnb_metrics.sh
# Run on gnb1 (pc818) or gnb2 (pc802).
# Reads the srsenb per-UE metrics CSVs (written every 1s by srsenb itself)
# and aggregates them every INTERVAL seconds into a combined gNB CSV.
#
# srsenb metrics CSV columns (semicolon-separated):
#   timestamp;nof_ue;dl_brate;ul_brate;dl_nof_ok;dl_nof_nok;
#   ul_nof_ok;ul_nof_nok;dl_sched_usign;ul_sched_usign;phr;last_ta;sys_load
#
# Output: /tmp/ran_collect/gnb_metrics.csv  (comma-separated, with gnb_id and ue_slot)
# ============================================================
INTERVAL=${1:-5}
DURATION=${2:-7200}
GNB_ID=${3:-gnb1}        # gnb1 or gnb2
START_UE=${4:-1}          # 1 for gnb1, 51 for gnb2
END_UE=${5:-50}           # 50 for gnb1, 100 for gnb2

COLLECT_DIR=/tmp/ran_collect
mkdir -p "$COLLECT_DIR"
OUT="$COLLECT_DIR/gnb_metrics.csv"

HEADER="timestamp,gnb_id,ue_slot,nof_ue,dl_brate_mbps,ul_brate_mbps,\
dl_nof_ok,dl_nof_nok,ul_nof_ok,ul_nof_nok,\
dl_sched_usign,ul_sched_usign,phr,last_ta,sys_load,phase"

if [ ! -f "$OUT" ]; then
    echo "$HEADER" > "$OUT"
fi

echo "[collect_gnb] $GNB_ID UE${START_UE}-${END_UE} interval=${INTERVAL}s"
PHASE="baseline"
START=$(date +%s)

# Track last line read per UE (to only read new rows)
declare -A LAST_LINE

while true; do
    NOW=$(date +%s)
    [ $((NOW - START)) -ge $DURATION ] && break
    TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    [ -f /tmp/ran_collect/phase.txt ] && PHASE=$(cat /tmp/ran_collect/phase.txt)

    for i in $(seq $START_UE $END_UE); do
        METRICS_FILE="/tmp/${GNB_ID}_ue${i}_metrics.csv"
        [ ! -f "$METRICS_FILE" ] && continue

        # Get the last data line (most recent 1s sample)
        LINE=$(tail -1 "$METRICS_FILE" 2>/dev/null)
        [ -z "$LINE" ] && continue
        # Skip header line
        echo "$LINE" | grep -q "^timestamp\|^nof_ue\|^TTI" && continue

        # Parse semicolon-separated: timestamp;nof_ue;dl_brate;ul_brate;dl_nof_ok;dl_nof_nok;ul_nof_ok;ul_nof_nok;dl_sched;ul_sched;phr;last_ta;sys_load
        IFS=';' read -r _ts NOF_UE DL_BRATE UL_BRATE DL_OK DL_NOK UL_OK UL_NOK DL_SCHED UL_SCHED PHR LAST_TA SYS_LOAD <<< "$LINE"

        # Convert brate from bps to Mbps
        DL_MBPS=$(echo "scale=3; ${DL_BRATE:-0}/1000000" | bc 2>/dev/null || echo "0")
        UL_MBPS=$(echo "scale=3; ${UL_BRATE:-0}/1000000" | bc 2>/dev/null || echo "0")

        echo "${TS},${GNB_ID},${i},${NOF_UE:-0},${DL_MBPS},${UL_MBPS},${DL_OK:-0},${DL_NOK:-0},${UL_OK:-0},${UL_NOK:-0},${DL_SCHED:-0},${UL_SCHED:-0},${PHR:-0},${LAST_TA:-0},${SYS_LOAD:-0},${PHASE}" >> "$OUT"
    done

    sleep "$INTERVAL"
done

echo "[collect_gnb] Done. Output: $OUT"
