#!/bin/bash
# measure_throughput_all_ues.sh
# Run on uehost1 (pc808).
# For each UE:
#   1. Runs UDP background flood to prime the radio scheduler
#   2. Measures achievable DL and UL at: 1M, 5M, 10M, 15M Mbps targets
#   3. Writes per-UE and combined results to CSV
#
# Usage: bash measure_throughput_all_ues.sh [start] [end] [server_ip]

START=${1:-1}
END=${2:-49}
SERVER=${3:-10.45.0.1}
COLLECT=/tmp/ran_collect
mkdir -p $COLLECT

OUT="$COLLECT/throughput_all_ues.csv"
echo "timestamp,ue_id,ip,direction,target_mbps,actual_mbps,transfer_mb,duration_s,retransmits,protocol" > $OUT

echo "=== Throughput measurement UE${START}-UE${END} server=${SERVER} ==="

for i in $(seq $START $END); do
  NS=ue${i}
  IP=$(sudo ip netns exec $NS ip -br a 2>/dev/null | grep tun | awk '{print $3}' | cut -d/ -f1)
  if [ -z "$IP" ]; then
    echo "UE${i}: not attached — skip"
    continue
  fi

  echo ""
  echo "=== UE${i} ($IP) ==="

  # Tune TCP inside the netns
  sudo ip netns exec $NS sysctl -qw net.core.rmem_max=26214400
  sudo ip netns exec $NS sysctl -qw net.core.wmem_max=26214400
  sudo ip netns exec $NS sysctl -qw net.ipv4.tcp_rmem="4096 87380 26214400"
  sudo ip netns exec $NS sysctl -qw net.ipv4.tcp_wmem="4096 87380 26214400"

  # ── Step 1: Prime the scheduler with a 3s UDP burst ──────────────────
  sudo ip netns exec $NS iperf3 -c $SERVER -u -b 30M -t 3 -l 1400 > /dev/null 2>&1 &
  PRIME_PID=$!
  sleep 3
  kill $PRIME_PID 2>/dev/null

  # ── Step 2: Measure at ramp levels matched to ZMQ 10MHz capacity ──────
  # ZMQ 10MHz max ~8Mbps DL, so ramp: low=0.5M, mid=2M, high=5M, max=8M
  for TARGET in 0.5 1 2 5 8; do
    BPS=$((TARGET * 1000000))
    TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # DL (server → UE)  — reverse UDP
    echo -n "  UE${i} DL ${TARGET}Mbps UDP... "
    RES=$(sudo ip netns exec $NS iperf3 -c $SERVER -u -b ${BPS} -t 8 -R -l 1400 --json 2>/dev/null)
    DL_ACT=$(echo "$RES" | python3 -c "
import sys,json
try:
  d=json.load(sys.stdin)
  r=d['end']['sum']
  bps=r.get('bits_per_second',0)
  mb=r.get('bytes',0)/1e6
  lost=d['end']['sum'].get('lost_packets',0)
  total=d['end']['sum'].get('packets',0)
  print(f'{bps/1e6:.3f},{mb:.2f},0,{lost}/{total}')
except Exception as e: print('0,0,0,0/0')
" 2>/dev/null)
    ACT=$(echo $DL_ACT | cut -d, -f1)
    echo "${ACT} Mbps"
    echo "$TS,$i,$IP,DL,$TARGET,${DL_ACT},udp" >> $OUT

    TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    # UL (UE → server)  — UDP
    echo -n "  UE${i} UL ${TARGET}Mbps UDP... "
    RES=$(sudo ip netns exec $NS iperf3 -c $SERVER -u -b ${BPS} -t 8 -l 1400 --json 2>/dev/null)
    UL_ACT=$(echo "$RES" | python3 -c "
import sys,json
try:
  d=json.load(sys.stdin)
  r=d['end']['sum']
  bps=r.get('bits_per_second',0)
  mb=r.get('bytes',0)/1e6
  lost=d['end']['sum'].get('lost_packets',0)
  total=d['end']['sum'].get('packets',0)
  print(f'{bps/1e6:.3f},{mb:.2f},0,{lost}/{total}')
except: print('0,0,0,0/0')
" 2>/dev/null)
    ACT=$(echo $UL_ACT | cut -d, -f1)
    echo "${ACT} Mbps"
    echo "$TS,$i,$IP,UL,$TARGET,${UL_ACT},udp" >> $OUT

    sleep 1
  done

  # ── Step 3: One TCP DL test (best-effort) ─────────────────────────────
  TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo -n "  UE${i} DL TCP best-effort... "
  RES=$(sudo ip netns exec $NS iperf3 -c $SERVER -R -t 10 --json 2>/dev/null)
  TCP_ACT=$(echo "$RES" | python3 -c "
import sys,json
try:
  d=json.load(sys.stdin)
  r=d['end']['sum_received']
  bps=r.get('bits_per_second',0)
  mb=r.get('bytes',0)/1e6
  ret=d['end']['sum_sent'].get('retransmits',0)
  print(f'{bps/1e6:.3f},{mb:.2f},{ret},0/0')
except: print('0,0,0,0/0')
" 2>/dev/null)
  ACT=$(echo $TCP_ACT | cut -d, -f1)
  echo "${ACT} Mbps"
  echo "$TS,$i,$IP,DL,0,${TCP_ACT},tcp" >> $OUT

done

echo ""
echo "=== Done. Results: $OUT ($(wc -l < $OUT) rows) ==="
