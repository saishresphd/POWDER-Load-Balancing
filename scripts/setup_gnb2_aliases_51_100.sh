#!/bin/bash
# Add IP aliases on gnb2 for UE52-100 base slots → 10.10.1.149-197
# and LB targets 101-110 → 10.10.1.210-219
DEV=enp6s0f3

add_alias() {
  local ip=$1
  if ! ip addr show dev $DEV | grep -q "${ip}/"; then
    sudo ip addr add ${ip}/24 dev $DEV
    echo "Added $ip"
  fi
}

# UE51 uses primary 10.10.1.3 — no alias needed
# UE52-100 → 10.10.1.149-197
for i in $(seq 52 100); do
  add_alias "10.10.1.$((97 + i))"
done

echo "gnb2 aliases: $(ip addr show dev $DEV | grep 'inet 10.10.1' | wc -l) total"
