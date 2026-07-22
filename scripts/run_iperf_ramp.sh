#!/bin/bash
# ============================================================
# run_iperf_ramp.sh
# Run on uehost1 (pc808) or uehost2 (pc801).
# For each attached UE, runs iperf3 DL+UL in the UE's netns,
# ramping bandwidth from 100Kbps → 1Mbps → 5Mbps → 10Mbps → 20Mbps.
# Results are written to /tmp/ran_collect/iperf_results.csv
#
# Requires: iperf3 server running on core (pc811) inside ogstun namespace
#           or reachable at 10.45.0.1 from UE netns.
#
# Usage: bash run_iperf_ramp.sh <start_ue> <end_ue> [server_ip]
# ============================================================
START_UE=${1:-1}
END_UE=${2:-50}
SERVER_IP=${3:-10.45.0.1}
COLLECT_DIR=/tmp/ran_collect
mkdir -p "$COLLECT_DIR"
OUT="$COLLECT_DIR/iperf_results.csv"
DURATION=10   # seconds per iperf run

# Throughput ramp steps (Mbps)
RAMP_STEPS="0.1 0.5 1 2 5 10 20"

HEADER="timestamp,ue_id,netns,direction,target_mbps,actual_mbps,\
transfer_mb,duration_s,retransmits,jitter_ms,lost_pct,phase"
if [ ! -f "$OUT" ]; then
    echo "$HEADER" > "$OUT"
fi

PHASE="baseline"
[ -f /tmp/ran_collect/phase.txt ] && PHASE=$(cat /tmp/ran_collect/phase.txt)

echo "[iperf_ramp] UE${START_UE}-${END_UE} server=${SERVER_IP}"

# Check iperf3 installed
if ! command -v iperf3 &>/dev/null; then
    echo "[iperf_ramp] iperf3 not found — installing..."
    sudo apt-get install -y iperf3 -qq
fi

run_iperf_for_ue() {
    local UE=$1
    local NS="ue${UE}"

    # Check UE is attached
    ADDR=$(sudo ip netns exec "$NS" ip -br a 2>/dev/null | grep tun | awk '{print $3}')
    if [ -z "$ADDR" ]; then
        echo "[iperf_ramp] UE${UE}: not attached, skip"
        return
    fi

    [ -f /tmp/ran_collect/phase.txt ] && PHASE=$(cat /tmp/ran_collect/phase.txt)
    echo "[iperf_ramp] UE${UE} ($ADDR) testing against $SERVER_IP"

    for BW in $RAMP_STEPS; do
        BW_BPS=$(echo "scale=0; $BW*1000000/1" | bc)
        TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

        # ── Downlink (server→UE): iperf3 reverse mode ──
        DL_JSON=$(sudo ip netns exec "$NS" iperf3 \
            -c "$SERVER_IP" -R \
            -b "${BW_BPS}" -t "$DURATION" \
            -J --logfile /dev/null 2>/dev/null || echo "{}")

        DL_MBPS=$(echo "$DL_JSON" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    bps=d['end']['sum_received']['bits_per_second']
    print(f'{bps/1e6:.3f}')
except: print('0')
" 2>/dev/null || echo "0")

        DL_MB=$(echo "$DL_JSON" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(f\"{d['end']['sum_received']['bytes']/1e6:.2f}\")
except: print('0')
" 2>/dev/null || echo "0")

        RETRANS=$(echo "$DL_JSON" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(d['end']['sum_sent'].get('retransmits',0))
except: print('0')
" 2>/dev/null || echo "0")

        echo "${TS},${UE},${NS},DL,${BW},${DL_MBPS},${DL_MB},${DURATION},${RETRANS},0,0,${PHASE}" >> "$OUT"

        # ── Uplink (UE→server) ──
        TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        UL_JSON=$(sudo ip netns exec "$NS" iperf3 \
            -c "$SERVER_IP" \
            -b "${BW_BPS}" -t "$DURATION" \
            -J --logfile /dev/null 2>/dev/null || echo "{}")

        UL_MBPS=$(echo "$UL_JSON" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    bps=d['end']['sum_sent']['bits_per_second']
    print(f'{bps/1e6:.3f}')
except: print('0')
" 2>/dev/null || echo "0")

        UL_MB=$(echo "$UL_JSON" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(f\"{d['end']['sum_sent']['bytes']/1e6:.2f}\")
except: print('0')
" 2>/dev/null || echo "0")

        RETRANS=$(echo "$UL_JSON" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(d['end']['sum_sent'].get('retransmits',0))
except: print('0')
" 2>/dev/null || echo "0")

        echo "${TS},${UE},${NS},UL,${BW},${UL_MBPS},${UL_MB},${DURATION},${RETRANS},0,0,${PHASE}" >> "$OUT"

        sleep 1
    done
    echo "[iperf_ramp] UE${UE} done"
}

# Run UEs in parallel groups of 5 to avoid overwhelming network
for batch_start in $(seq $START_UE 5 $END_UE); do
    batch_end=$((batch_start + 4))
    [ $batch_end -gt $END_UE ] && batch_end=$END_UE
    echo "[iperf_ramp] Batch UE${batch_start}-${batch_end}"
    for ue in $(seq $batch_start $batch_end); do
        run_iperf_for_ue $ue &
    done
    wait
done

echo "[iperf_ramp] All done. Results: $OUT ($(wc -l < $OUT) rows)"
