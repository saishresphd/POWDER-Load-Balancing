#!/bin/bash
# ─── setup_gnb2_ue101_110.sh ─────────────────────────────────────────────────
# Run ON pc802 (gnb2). Adds IP aliases for UE101-110 LB target slots.
set -e
DEV=enp6s0f3

add_alias() {
  local ip=$1
  if ! ip addr show dev $DEV | grep -q "$ip/"; then
    sudo ip addr add ${ip}/24 dev $DEV
    echo "Added alias $ip"
  else
    echo "Alias $ip already present"
  fi
}

echo "=== Adding IP aliases on gNB2 (pc802) ==="
# UE101-110 LB target slots → 10.10.1.210 to 10.10.1.219
for j in $(seq 1 10); do
  add_alias "10.10.1.$((209 + j))"
done

echo ""
echo "=== Current 10.10.1.x aliases on gNB2 ==="
ip addr show dev $DEV | grep 'inet 10.10.1' | wc -l
echo "aliases total"
