#!/bin/bash
# ==========================================================================
#  start_ues_host2.sh  — Start UE 11-20 sequentially on uehost2
# ==========================================================================
set -euo pipefail

LOG_DIR=/tmp/ue_logs
mkdir -p $LOG_DIR
PIDS=()

echo "[uehost2] Starting 10 srsUE instances (UE11-20)..."

for i in $(seq 11 20); do
    echo "  Starting UE${i} (IMSI=99970$(printf '%010d' $i))..."
    sudo srsue /etc/srsue/ue${i}.conf \
        >> ${LOG_DIR}/ue${i}_stdout.log 2>&1 &
    PIDS+=($!)
    sleep 1
done

echo "[uehost2] All 10 UEs started. PIDs: ${PIDS[*]}"
printf '%s\n' "${PIDS[@]}" > /tmp/ue_pids_host2.txt
