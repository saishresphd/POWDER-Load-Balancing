#!/bin/bash
# ─── start_ues_uehost1.sh ────────────────────────────────────────────────────
# Run ON pc808 (uehost1). Starts srsue for UE1-100 in batches.
# Waits for each UE to attach before starting the next.
mkdir -p /tmp/ue_logs

START=${1:-1}
END=${2:-100}
WAIT=${3:-30}   # seconds to wait for attach per UE

PASS=0
FAIL=0

echo "=== Starting srsue instances UE${START}-UE${END} (wait ${WAIT}s each) ==="
for i in $(seq $START $END); do
  CONF=/etc/srsue/ue${i}.conf
  if [ ! -f "$CONF" ]; then
    echo "UE${i}: config missing at $CONF — SKIP"
    continue
  fi

  if ps aux | grep "[s]rsue.*ue${i}.conf" > /dev/null 2>&1; then
    echo "UE${i}: already running"
    PASS=$((PASS+1))
    continue
  fi

  echo -n "UE${i}: starting... "
  sudo bash -c "srsue $CONF >> /tmp/ue_logs/ue${i}_stdout.log 2>&1 &"
  sleep $WAIT

  ADDR=$(sudo ip netns exec ue${i} ip -br a 2>/dev/null | grep tun | awk '{print $3}')
  if [ -n "$ADDR" ]; then
    echo "ATTACHED ($ADDR)"
    PASS=$((PASS+1))
  else
    echo "NOT_ATTACHED (check /tmp/ue_logs/ue${i}_stdout.log)"
    FAIL=$((FAIL+1))
  fi
done

echo ""
echo "=== Summary: ${PASS} attached / ${FAIL} failed out of $((PASS+FAIL)) ==="
