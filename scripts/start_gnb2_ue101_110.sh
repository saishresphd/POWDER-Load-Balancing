#!/bin/bash
# ─── start_gnb2_ue101_110.sh ─────────────────────────────────────────────────
# Run ON pc802 (gnb2). Starts srsenb LB target slots 101-110.
mkdir -p /tmp/gnb2_logs

echo "=== Starting gNB2 srsenb instances UE101-UE110 ==="
for i in $(seq 101 110); do
  if ! ps aux | grep "[s]rsenb.*enb_ue${i}.conf" > /dev/null 2>&1; then
    sudo bash -c "srsenb /etc/srsenb/enb_ue${i}.conf >> /tmp/gnb2_logs/ue${i}_stdout.log 2>&1 &"
    echo "Started enb_ue${i}"
    sleep 1
  else
    echo "enb_ue${i} already running, skipping"
  fi
done

sleep 10
echo "Running srsenb count: $(ps aux | grep '[s]rsenb' | wc -l)"
