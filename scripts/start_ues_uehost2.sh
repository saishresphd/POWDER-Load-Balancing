#!/bin/bash
# ─── start_ues_uehost2.sh ────────────────────────────────────────────────────
# Run ON pc801 (uehost2). Starts srsue for UE101-110 pointing to gNB2.
mkdir -p /tmp/ue_logs

WAIT=${1:-30}
PASS=0
FAIL=0

echo "=== Starting srsue instances UE101-UE110 (wait ${WAIT}s each) ==="
for i in $(seq 101 110); do
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
