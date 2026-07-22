#!/bin/bash
# run_iperf_per_ue.sh — Run on uehost1 (pc808)
# Runs iperf3 DL+UL for each attached UE in sequence
# Ramps: 1Mbps → 5Mbps → 10Mbps → 20Mbps → 50Mbps
# Writes per-UE per-step results to /tmp/ran_collect/iperf_ue{N}.csv
#        and combined to /tmp/ran_collect/iperf_all.csv

START_UE=${1:-1}
END_UE=${2:-50}
SERVER=${3:-10.45.0.1}
COLLECT_DIR=/tmp/ran_collect
mkdir -p "$COLLECT_DIR"
COMBINED="$COLLECT_DIR/iperf_all.csv"
DURATION=8    # seconds per iperf test

echo "timestamp,ue_id,direction,target_mbps,actual_mbps,transfer_mb,retransmits,jitter_ms,cpu_sender_pct,cpu_receiver_pct" > "$COMBINED"

# Ramp steps in Mbps
STEPS="1 5 10 20 50"

echo "[iperf] UE${START_UE}-${END_UE} server=${SERVER} steps=${STEPS}"

for i in $(seq $START_UE $END_UE); do
  NS="ue${i}"
  IP=$(sudo ip netns exec $NS ip -br a 2>/dev/null | grep tun | awk '{print $3}')
  if [ -z "$IP" ]; then
    echo "UE${i}: not attached — skip"
    continue
  fi
  echo "--- UE${i} ($IP) ---"

  PER_UE="$COLLECT_DIR/iperf_ue${i}.csv"
  echo "timestamp,target_mbps,dl_actual_mbps,ul_actual_mbps" > "$PER_UE"

  for BW in $STEPS; do
    BW_BPS=$((BW * 1000000))
    TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo -n "  UE${i} ${BW}Mbps DL... "

    # DL (reverse = server sends to UE)
    DL_JSON=$(sudo ip netns exec $NS iperf3 -c $SERVER -R -b ${BW_BPS} -t $DURATION -J 2>/dev/null || echo '{}')
    DL_MBPS=$(python3 -c "
import json,sys
try:
  d=json.loads(sys.stdin.read())
  bps=d['end']['sum_received']['bits_per_second']
  ret=d['end']['sum_sent'].get('retransmits',0)
  cpu_s=d['end']['cpu_utilization_percent']['host_total']
  cpu_r=d['end']['cpu_utilization_percent']['remote_total']
  mb=d['end']['sum_received']['bytes']/1e6
  print(f'{bps/1e6:.3f},{mb:.2f},{ret},{cpu_s:.1f},{cpu_r:.1f}')
except: print('0,0,0,0,0')
" <<< "$DL_JSON")
    DL_ACT=$(echo "$DL_MBPS" | cut -d, -f1)
    echo -n "${DL_ACT}Mbps  UL... "

    TS2=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    # UL (UE sends to server)
    UL_JSON=$(sudo ip netns exec $NS iperf3 -c $SERVER -b ${BW_BPS} -t $DURATION -J 2>/dev/null || echo '{}')
    UL_MBPS=$(python3 -c "
import json,sys
try:
  d=json.loads(sys.stdin.read())
  bps=d['end']['sum_sent']['bits_per_second']
  ret=d['end']['sum_sent'].get('retransmits',0)
  cpu_s=d['end']['cpu_utilization_percent']['host_total']
  cpu_r=d['end']['cpu_utilization_percent']['remote_total']
  mb=d['end']['sum_sent']['bytes']/1e6
  print(f'{bps/1e6:.3f},{mb:.2f},{ret},{cpu_s:.1f},{cpu_r:.1f}')
except: print('0,0,0,0,0')
" <<< "$UL_JSON")
    UL_ACT=$(echo "$UL_MBPS" | cut -d, -f1)
    echo "${UL_ACT}Mbps"

    # Write to per-UE csv
    echo "$TS,$BW,$DL_ACT,$UL_ACT" >> "$PER_UE"

    # Write DL row to combined
    echo "$TS,$i,DL,$BW,${DL_MBPS}" >> "$COMBINED"
    # Write UL row to combined
    echo "$TS2,$i,UL,$BW,${UL_MBPS}" >> "$COMBINED"

    sleep 1
  done
done

echo "[iperf] Done. Combined: $COMBINED ($(wc -l < $COMBINED) rows)"
