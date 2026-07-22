#!/bin/bash
# install_ue_confs_51_100.sh — run on pc801 (uehost2)
# Installs UE51-100 configs from /tmp and creates netns ue51-ue100
set -e

echo "=== Extracting UE51-100 configs ==="
cd /tmp && tar xzf ues_51_100_gnb2.tgz 2>/dev/null | grep -v LIBARCHIVE || true

echo "=== Installing to /etc/srsue/ ==="
for i in $(seq 51 100); do
  if [ -f /tmp/ue${i}.conf ]; then
    sudo cp /tmp/ue${i}.conf /etc/srsue/
  fi
done
echo "Installed: $(ls /etc/srsue/ue*.conf | wc -l) configs total"

echo "=== Creating netns ue51-ue100 ==="
for i in $(seq 51 100); do
  if ! sudo ip netns list 2>/dev/null | grep -qw "ue${i}"; then
    sudo ip netns add ue${i}
    echo "  Created ue${i}"
  fi
done
echo "Total netns: $(sudo ip netns list | wc -l)"
