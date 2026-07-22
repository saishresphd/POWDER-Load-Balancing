#!/bin/bash
# start_ues_51_100.sh — run on pc801 (uehost2)
# Starts srsue for UE51-100, each pointing at gNB2 (pc802)
mkdir -p /tmp/ue_logs

START=${1:-51}
END=${2:-100}
WAIT=${3:-20}

PASS=0
FAIL=0

echo "=== Starting srsue UE${START}-UE${END} on uehost2 (wait ${WAIT}s each) ==="
for i in $(seq $START $END); do
  CONF=/etc/srsue/ue${i}.conf
  if [ ! -f "$CONF" ]; then
    echo "UE${i}: config missing — SKIP"
    FAIL=$((FAIL+1))
    continue
  fi

  if ps aux | grep "[s]rsue.*ue${i}\.conf" > /dev/null 2>&1; then
    ADDR=$(sudo ip netns exec ue${i} ip -br a 2>/dev/null | grep tun | awk '{print $3}')
    echo "UE${i}: already running (${ADDR:-no IP yet})"
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
    echo "NOT_ATTACHED — check /tmp/ue_logs/ue${i}_stdout.log"
    FAIL=$((FAIL+1))
  fi
done

echo ""
echo "=== Summary: ${PASS} attached / ${FAIL} failed out of $((PASS+FAIL)) ==="
