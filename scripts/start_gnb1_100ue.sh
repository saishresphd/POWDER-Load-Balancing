#!/bin/bash
# ─── start_gnb1_100ue.sh ─────────────────────────────────────────────────────
# Run ON pc818 (gnb1). Starts srsenb slots 1-100 (base UEs) + 101-110 (LB slots).
# Each instance connects to one UE via ZMQ.
mkdir -p /tmp/gnb1_logs

START=${1:-1}
END=${2:-100}

echo "=== Starting gNB1 srsenb instances UE${START}-UE${END} ==="
for i in $(seq $START $END); do
  if ! ps aux | grep "[s]rsenb.*enb_ue${i}.conf" > /dev/null 2>&1; then
    sudo bash -c "srsenb /etc/srsenb/enb_ue${i}.conf >> /tmp/gnb1_logs/ue${i}_stdout.log 2>&1 &"
    echo "Started enb_ue${i} (PID $!)"
    # Stagger starts to avoid overwhelming the MME
    sleep 1
  else
    echo "enb_ue${i} already running, skipping"
  fi
done

echo ""
echo "Waiting 10s for gNBs to register with MME..."
sleep 10
echo "Running srsenb count: $(ps aux | grep '[s]rsenb' | wc -l)"
