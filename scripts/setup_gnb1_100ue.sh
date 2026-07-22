#!/bin/bash
# ─── setup_gnb1_100ue.sh ─────────────────────────────────────────────────────
# Run ON pc818 (gnb1). Adds IP aliases for UE1-100 base slots + UE101-110 LB.
# Idempotent — skip if alias already present.
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

echo "=== Adding IP aliases on gNB1 (pc818) ==="
# UE1 uses primary 10.10.1.2 — no alias needed
# UE2-100 → 10.10.1.100 to 10.10.1.198
for i in $(seq 2 100); do
  add_alias "10.10.1.$((98 + i))"
done

# UE101-110 LB slots → 10.10.1.200 to 10.10.1.209
for j in $(seq 1 10); do
  add_alias "10.10.1.$((199 + j))"
done

echo ""
echo "=== Current 10.10.1.x aliases on gNB1 ==="
ip addr show dev $DEV | grep 'inet 10.10.1' | wc -l
echo "aliases total"
