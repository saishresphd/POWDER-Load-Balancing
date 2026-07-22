#!/bin/bash
# Kill gnb1 srsenb instances for UE51-100 (we moved those to gnb2)
# Keep UE1-50 and UE101-110 running.
echo "Killing enb_ue51-100 on gnb1..."
for i in $(seq 51 100); do
  PID=$(ps aux | grep "[s]rsenb.*enb_ue${i}\.conf" | awk '{print $2}')
  if [ -n "$PID" ]; then
    sudo kill -9 $PID && echo "Killed enb_ue${i} (PID $PID)"
  fi
done
sleep 2
echo "Remaining srsenb count: $(ps aux | grep '[s]rsenb' | wc -l)"
echo "Memory free: $(free -h | grep Mem | awk '{print $7}')"
