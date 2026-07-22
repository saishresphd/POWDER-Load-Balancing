#!/bin/bash
# Start gnb2 srsenb instances for UE51-100
mkdir -p /tmp/gnb2_logs

START=${1:-51}
END=${2:-100}

echo "=== Starting gNB2 srsenb UE${START}-UE${END} ==="
for i in $(seq $START $END); do
  if ! ps aux | grep "[s]rsenb.*enb_ue${i}\.conf" > /dev/null 2>&1; then
    sudo bash -c "srsenb /etc/srsenb/enb_ue${i}.conf >> /tmp/gnb2_logs/ue${i}_stdout.log 2>&1 &"
    echo "Started enb_ue${i}"
    sleep 1
  else
    echo "enb_ue${i} already running"
  fi
done

sleep 10
echo "gnb2 running srsenb count: $(ps aux | grep '[s]rsenb' | wc -l)"
echo "Memory: $(free -h | grep Mem | awk '{print $3}') used / $(free -h | grep Mem | awk '{print $2}') total"
