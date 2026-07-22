#!/bin/bash
# deploy_gnb2_v4.sh — run on pc802. Final deploy: s1c=10.10.1.3, gtp=unique alias
echo "=== Extracting ==="
cd /tmp && tar xzf gnb2_enb_51_110_v4.tgz 2>/dev/null | grep -v LIBARCHIVE || true

echo "=== Installing ==="
for i in $(seq 51 110); do sudo cp /tmp/enb_ue${i}.conf /etc/srsenb/; done
echo "s1c UE52: $(grep s1c_bind_addr /etc/srsenb/enb_ue52.conf)"
echo "gtp UE52: $(grep gtp_bind_addr /etc/srsenb/enb_ue52.conf)"

echo "=== Restarting enb_ue51-110 ==="
for i in $(seq 51 110); do
  PID=$(ps aux | grep "[s]rsenb.*enb_ue${i}\.conf" | awk '{print $2}')
  [ -n "$PID" ] && sudo kill -9 $PID
done
sleep 3
mkdir -p /tmp/gnb2_logs
for i in $(seq 51 110); do
  sudo bash -c "srsenb /etc/srsenb/enb_ue${i}.conf >> /tmp/gnb2_logs/ue${i}_stdout.log 2>&1 &"
  sleep 0.5
done
sleep 15
RUNNING=$(ps aux | grep '[s]rsenb' | wc -l)
echo "gnb2 running: $RUNNING"
echo "RAM: $(free -h | grep Mem | awk '{print $3}') used"
[ "$RUNNING" -gt 0 ] && echo "SUCCESS: gNB2 instances up" || echo "FAIL: no srsenb running"
