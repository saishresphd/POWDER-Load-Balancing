#!/bin/bash
# ─── setup_netns_uehost1.sh ──────────────────────────────────────────────────
# Run ON pc808 (uehost1). Creates netns ue1-ue100. Idempotent.
echo "=== Creating network namespaces ue1-ue100 ==="
for i in $(seq 1 100); do
  if ! sudo ip netns list | grep -qw "ue${i}"; then
    sudo ip netns add ue${i}
    echo "Created ue${i}"
  fi
done
echo ""
echo "Total netns: $(sudo ip netns list | wc -l)"
