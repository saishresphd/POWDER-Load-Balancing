#!/bin/bash
# ==========================================================================
#  start_ues_host1.sh  — Start UE 1-10 sequentially on uehost1
#  Each UE starts in background, waits for attach before next one
# ==========================================================================
set -euo pipefail

LOG_DIR=/tmp/ue_logs
mkdir -p $LOG_DIR
PIDS=()

echo "[uehost1] Starting 10 srsUE instances..."

for i in $(seq 1 10); do
    echo "  Starting UE${i} (IMSI=99970$(printf '%010d' $i))..."
    sudo srsue /etc/srsue/ue${i}.conf \
        >> ${LOG_DIR}/ue${i}_stdout.log 2>&1 &
    PIDS+=($!)
    sleep 1   # stagger start to avoid RACH collision
done

echo "[uehost1] All 10 UEs started. PIDs: ${PIDS[*]}"
echo "PIDs saved to /tmp/ue_pids_host1.txt"
printf '%s\n' "${PIDS[@]}" > /tmp/ue_pids_host1.txt

echo "Monitor: tail -f /tmp/ue_logs/ue{1..10}_stdout.log"
echo "Check attach: for i in \$(seq 1 10); do ip netns exec ue\$i ip addr; done"
