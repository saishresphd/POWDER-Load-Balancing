#!/bin/bash
# deploy_gnb2_v3.sh — run on pc802
# Fixes s1c_bind_addr to always use primary 10.10.1.3 for S1AP
echo "=== Extracting ==="
cd /tmp && tar xzf gnb2_enb_51_110_v3.tgz 2>/dev/null | grep -v LIBARCHIVE || true

echo "=== Installing ==="
for i in $(seq 51 110); do sudo cp /tmp/enb_ue${i}.conf /etc/srsenb/; done
echo "Verify UE52 s1c: $(grep s1c_bind_addr /etc/srsenb/enb_ue52.conf)"
echo "Verify UE52 gtp: $(grep gtp_bind_addr /etc/srsenb/enb_ue52.conf)"

echo "=== Killing enb_ue51-110 ==="
for i in $(seq 51 110); do
  PID=$(ps aux | grep "[s]rsenb.*enb_ue${i}\.conf" | awk '{print $2}')
  [ -n "$PID" ] && sudo kill -9 $PID && echo "  Killed enb_ue${i}"
done
sleep 3

echo "=== Restarting ==="
mkdir -p /tmp/gnb2_logs
for i in $(seq 51 110); do
  sudo bash -c "srsenb /etc/srsenb/enb_ue${i}.conf >> /tmp/gnb2_logs/ue${i}_stdout.log 2>&1 &"
  sleep 0.5
done
sleep 15
echo "gnb2 count: $(ps aux | grep '[s]rsenb' | wc -l)"
echo "RAM: $(free -h | grep Mem | awk '{print $3}') used / $(free -h | grep Mem | awk '{print $2}')"
