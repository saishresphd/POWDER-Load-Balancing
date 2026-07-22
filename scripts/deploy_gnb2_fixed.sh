#!/bin/bash
# deploy_gnb2_fixed.sh — run on pc802
# Extracts fixed enb_ue51-100 configs and restarts those srsenb instances

echo "=== Extracting fixed configs ==="
cd /tmp && tar xzf gnb2_enb_51_100_fixed.tgz 2>/dev/null | grep -v LIBARCHIVE || true

echo "=== Installing configs to /etc/srsenb/ ==="
for i in $(seq 51 100); do
  sudo cp /tmp/enb_ue${i}.conf /etc/srsenb/
done
echo "Updated: $(ls /etc/srsenb/enb_ue*.conf | wc -l) enb configs total"

echo "=== Verifying fix on enb_ue51 ==="
grep rx_port /etc/srsenb/enb_ue51.conf

echo "=== Killing old gnb2 srsenb UE51-100 instances ==="
for i in $(seq 51 100); do
  PID=$(ps aux | grep "[s]rsenb.*enb_ue${i}\.conf" | awk '{print $2}')
  if [ -n "$PID" ]; then
    sudo kill -9 $PID && echo "  Killed enb_ue${i} PID=$PID"
  fi
done

sleep 3

echo "=== Restarting gnb2 srsenb UE51-100 with fixed rx_port ==="
mkdir -p /tmp/gnb2_logs
for i in $(seq 51 100); do
  sudo bash -c "srsenb /etc/srsenb/enb_ue${i}.conf >> /tmp/gnb2_logs/ue${i}_stdout.log 2>&1 &"
  sleep 0.5
done

sleep 10
echo "=== gnb2 srsenb count: $(ps aux | grep '[s]rsenb' | wc -l) ==="
echo "=== Memory: $(free -h | grep Mem | awk '{print $3}') used / $(free -h | grep Mem | awk '{print $2}') total ==="
