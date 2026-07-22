#!/bin/bash
# attach_ue_one_by_one.sh
# Starts srsue for UE START..END one at a time.
# Waits for attach, verifies IP, then moves to next.
# Writes per-UE attach log to /tmp/ran_collect/attach_log.csv
#
# Usage: bash attach_ue_one_by_one.sh <start> <end> [wait_sec]

START=${1:-1}
END=${2:-50}
WAIT=${3:-30}
COLLECT_DIR=/tmp/ran_collect
mkdir -p "$COLLECT_DIR"
LOG="$COLLECT_DIR/attach_log.csv"
STDOUTDIR=/tmp/ue_logs
mkdir -p "$STDOUTDIR"

HEADER="timestamp,ue_id,netns,status,ip_address,attach_time_sec,attempts"
[ ! -f "$LOG" ] && echo "$HEADER" > "$LOG"

TOTAL_PASS=0
TOTAL_FAIL=0

echo "=== Attaching UE${START}-UE${END} one by one (wait=${WAIT}s each) ==="

for i in $(seq $START $END); do
  CONF=/etc/srsue/ue${i}.conf
  NS=ue${i}

  if [ ! -f "$CONF" ]; then
    echo "UE${i}: SKIP — config missing"
    TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "$TS,$i,$NS,NO_CONFIG,,,0" >> "$LOG"
    continue
  fi

  # Kill any stale srsue for this UE
  STALE=$(ps aux | grep "[s]rsue.*ue${i}\.conf" | awk '{print $2}')
  if [ -n "$STALE" ]; then
    sudo kill -9 $STALE 2>/dev/null
    sleep 1
  fi

  T_START=$(date +%s)
  TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo -n "UE${i}: starting... "

  sudo bash -c "srsue $CONF >> $STDOUTDIR/ue${i}_stdout.log 2>&1 &"

  # Poll for attach (up to WAIT seconds)
  ADDR=""
  ELAPSED=0
  while [ $ELAPSED -lt $WAIT ]; do
    sleep 2
    ELAPSED=$((ELAPSED+2))
    ADDR=$(sudo ip netns exec "$NS" ip -br a 2>/dev/null | grep tun | awk '{print $3}')
    [ -n "$ADDR" ] && break
  done

  T_END=$(date +%s)
  ATTACH_TIME=$((T_END - T_START))

  if [ -n "$ADDR" ]; then
    echo "ATTACHED ($ADDR) in ${ATTACH_TIME}s"
    echo "$TS,$i,$NS,ATTACHED,$ADDR,$ATTACH_TIME,1" >> "$LOG"
    TOTAL_PASS=$((TOTAL_PASS+1))
  else
    # Try once more (gNB might be slow)
    echo -n "RETRY... "
    sleep 10
    ADDR=$(sudo ip netns exec "$NS" ip -br a 2>/dev/null | grep tun | awk '{print $3}')
    T_END2=$(date +%s)
    ATTACH_TIME2=$((T_END2 - T_START))
    if [ -n "$ADDR" ]; then
      echo "ATTACHED ($ADDR) in ${ATTACH_TIME2}s (retry)"
      echo "$TS,$i,$NS,ATTACHED,$ADDR,$ATTACH_TIME2,2" >> "$LOG"
      TOTAL_PASS=$((TOTAL_PASS+1))
    else
      echo "FAILED — check /tmp/ue_logs/ue${i}_stdout.log"
      echo "$TS,$i,$NS,FAILED,,$ATTACH_TIME2,2" >> "$LOG"
      TOTAL_FAIL=$((TOTAL_FAIL+1))
    fi
  fi
done

echo ""
echo "=== ATTACH SUMMARY: ${TOTAL_PASS} passed / ${TOTAL_FAIL} failed ==="
echo "Log: $LOG"
