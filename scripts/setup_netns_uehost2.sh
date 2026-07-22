#!/bin/bash
# ─── setup_netns_uehost2.sh ──────────────────────────────────────────────────
# Run ON pc801 (uehost2). Creates netns ue101-ue110. Idempotent.
echo "=== Creating network namespaces ue101-ue110 ==="
for i in $(seq 101 110); do
  if ! sudo ip netns list | grep -qw "ue${i}"; then
    sudo ip netns add ue${i}
    echo "Created ue${i}"
  fi
done
echo ""
echo "Total netns: $(sudo ip netns list | wc -l)"
