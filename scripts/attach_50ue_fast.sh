#!/bin/bash
# attach_50ue_fast.sh — attach UE1-50 one by one, NO retry on fail, move on.
# Logs per-UE result to /tmp/ran_collect/attach_log.csv

START=${1:-1}
END=${2:-50}
WAIT=${3:-30}

COLLECT_DIR=/tmp/ran_collect
mkdir -p "$COLLECT_DIR" /tmp/ue_logs

LOG="$COLLECT_DIR/attach_log.csv"
echo "timestamp,ue_id,status,ip_address,attach_sec" > "$LOG"

PASS=0; FAIL=0

echo "=== Attaching UE${START} to UE${END} (${WAIT}s wait, no retry) ==="

for i in $(seq $START $END); do
  CONF=/etc/srsue/ue${i}.conf
  if [ ! -f "$CONF" ]; then
    echo "UE${i}: SKIP (no config)"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ),$i,NO_CONFIG,," >> "$LOG"
    continue
  fi

  # Kill any stale process for this UE
  OLD=$(ps aux | grep "srsue.*ue${i}\.conf" | grep -v grep | awk '{print $2}')
  [ -n "$OLD" ] && sudo kill -9 $OLD 2>/dev/null && sleep 1

  T0=$(date +%s)
  TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf "UE%-3d: starting ... " "$i"
  sudo bash -c "srsue $CONF >> /tmp/ue_logs/ue${i}_stdout.log 2>&1 &"

  # Poll every 2s up to WAIT seconds
  ADDR=""
  for tick in $(seq 2 2 $WAIT); do
    sleep 2
    ADDR=$(sudo ip netns exec ue${i} ip -br a 2>/dev/null | grep tun | awk '{print $3}')
    [ -n "$ADDR" ] && break
  done

  T1=$(date +%s)
  ELAPSED=$((T1-T0))

  if [ -n "$ADDR" ]; then
    echo "ATTACHED  $ADDR  (${ELAPSED}s)"
    echo "$TS,$i,ATTACHED,$ADDR,$ELAPSED" >> "$LOG"
    PASS=$((PASS+1))
  else
    echo "FAILED    (moving on)"
    echo "$TS,$i,FAILED,,$ELAPSED" >> "$LOG"
    FAIL=$((FAIL+1))
    # Kill the stuck srsue so it doesn't consume ZMQ socket
    sudo bash -c "for PID in \$(ps aux | grep 'srsue.*ue${i}\.conf' | grep -v grep | awk '{print \$2}'); do kill -9 \$PID 2>/dev/null; done"
  fi
done

echo ""
echo "=== DONE: $PASS attached / $FAIL failed out of $((PASS+FAIL)) UEs ==="
echo "Log: $LOG"
