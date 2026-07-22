#!/bin/bash
# deploy_gnb2_v2.sh — run on pc802
# Deploys fixed enb_ue51-100 (valid port range 50010-50500) and restarts them
echo "=== Extracting ==="
cd /tmp && tar xzf gnb2_enb_51_100_v2.tgz 2>/dev/null | grep -v LIBARCHIVE || true

echo "=== Installing ==="
for i in $(seq 51 100); do sudo cp /tmp/enb_ue${i}.conf /etc/srsenb/; done
echo "Installed. Verify UE51: $(grep device_args /etc/srsenb/enb_ue51.conf)"

echo "=== Killing old enb_ue51-100 ==="
for i in $(seq 51 100); do
  PID=$(ps aux | grep "[s]rsenb.*enb_ue${i}\.conf" | awk '{print $2}')
  [ -n "$PID" ] && sudo kill -9 $PID && echo "  Killed enb_ue${i} PID=$PID"
done
sleep 3

echo "=== Restarting ==="
mkdir -p /tmp/gnb2_logs
for i in $(seq 51 100); do
  sudo bash -c "srsenb /etc/srsenb/enb_ue${i}.conf >> /tmp/gnb2_logs/ue${i}_stdout.log 2>&1 &"
  sleep 0.5
done
sleep 12
echo "gnb2 srsenb count: $(ps aux | grep '[s]rsenb' | wc -l)"
echo "Memory: $(free -h | grep Mem | awk '{print $3}') used"
