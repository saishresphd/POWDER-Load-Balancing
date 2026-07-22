#!/bin/bash
# ─── check_all_ues.sh ────────────────────────────────────────────────────────
# Run on uehost to report attach status and optionally ping for all UEs.
# Usage: bash check_all_ues.sh <START> <END> [ping]
#   e.g. bash check_all_ues.sh 1 100
#        bash check_all_ues.sh 1 100 ping

START=${1:-1}
END=${2:-100}
DO_PING=${3:-}

ATTACHED=0
FAILED=0

for i in $(seq $START $END); do
  ADDR=$(sudo ip netns exec ue${i} ip -br a 2>/dev/null | grep tun | awk '{print $3}')
  if [ -n "$ADDR" ]; then
    STATUS="ATTACHED $ADDR"
    ATTACHED=$((ATTACHED+1))
    if [ "$DO_PING" = "ping" ]; then
      LOSS=$(sudo ip netns exec ue${i} ping -c 2 -W 2 10.45.0.1 2>/dev/null \
             | grep -oP '\d+(?=% packet loss)' | head -1)
      STATUS="$STATUS ping=${LOSS:-?}%loss"
    fi
  else
    STATUS="NOT_ATTACHED"
    FAILED=$((FAILED+1))
  fi
  echo "UE${i}: $STATUS"
done

echo ""
echo "=== ${ATTACHED} attached / ${FAILED} not attached out of $((ATTACHED+FAILED)) UEs ==="
