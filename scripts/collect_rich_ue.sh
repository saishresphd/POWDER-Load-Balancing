#!/bin/bash
# collect_rich_ue.sh — Run on uehost1 (pc808)
# Parses srsUE logs per UE to extract:
#   SNR (sync), RSRP, CFO, MCS, PRB, TA, brate-from-log
# Also collects per-UE process memory (RSS/VSZ from /proc)
# Output: /tmp/ran_collect/ue_rich_uehost1.csv

HOST_ID=${1:-uehost1}
START_UE=${2:-1}
END_UE=${3:-50}
DURATION=${4:-100}
INTERVAL=${5:-2}
COLLECT_DIR=/tmp/ran_collect
mkdir -p "$COLLECT_DIR"
OUT="$COLLECT_DIR/ue_rich_${HOST_ID}.csv"

HDR="timestamp,host_id,ue_id,netns,ip_address,\
sync_snr_db,rsrp_dbm,cfo_hz,\
dl_mcs,dl_nof_prb,dl_tbs_bytes,\
ul_mcs,ul_nof_prb,ul_tbs_bytes,\
ta_us,pci,earfcn,\
proc_pid,proc_rss_mb,proc_vsz_mb,proc_cpu_pct,proc_threads,\
iperf_dl_mbps,iperf_ul_mbps,iperf_target_mbps"

echo "$HDR" > "$OUT"

echo "[collect_rich_ue] $HOST_ID UE${START_UE}-${END_UE} duration=${DURATION}s"
START=$(date +%s)

while [ $(( $(date +%s) - START )) -lt $DURATION ]; do
  TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  for i in $(seq $START_UE $END_UE); do
    NS="ue${i}"
    LOGFILE="/tmp/ue_logs/ue${i}_stdout.log"
    [ ! -f "$LOGFILE" ] && continue

    # Get IP
    IP=$(sudo ip netns exec $NS ip -br a 2>/dev/null | grep tun | awk '{print $3}' | cut -d/ -f1)
    [ -z "$IP" ] && IP="not_attached"

    # Read last 300 lines of log for measurements
    RECENT=$(tail -300 "$LOGFILE" 2>/dev/null)

    # Sync SNR
    SNR=$(echo "$RECENT" | grep 'SYNC:.*SNR=' | tail -1 | grep -oE 'SNR=[0-9.-]+' | cut -d= -f2)

    # RSRP from RRC MEAS
    RSRP=$(echo "$RECENT" | grep 'MEAS:.*rsrp=' | tail -1 | grep -oE 'rsrp=[0-9.-]+' | cut -d= -f2)
    CFO=$(echo "$RECENT" | grep 'MEAS:.*cfo=' | tail -1 | grep -oE 'cfo=[0-9.-]+' | cut -d= -f2)

    # PCI and EARFCN from cell search
    PCI=$(echo "$RECENT" | grep 'Found Cell:' | tail -1 | grep -oE 'PCI=[0-9]+' | cut -d= -f2)
    PRB_CELL=$(echo "$RECENT" | grep 'Found Cell:' | tail -1 | grep -oE 'PRB=[0-9]+' | cut -d= -f2)

    # DL MCS/PRB/TBS from PDSCH (from the UE side perspective - look for PDCCH decode)
    DL_MCS=""; DL_PRB=""; DL_TBS=""; UL_MCS=""; UL_PRB=""; UL_TBS=""; TA=""

    # TA from log
    TA=$(echo "$RECENT" | grep -oE 'ta=[0-9.-]+' | tail -1 | cut -d= -f2)

    # Process stats from /proc
    PID=$(ps aux | grep "srsue.*ue${i}\.conf" | grep -v grep | awk '{print $2}' | head -1)
    RSS_MB=""; VSZ_MB=""; CPU_PCT=""; THREADS=""
    if [ -n "$PID" ]; then
      read -r _ _ CPU_PCT _ VSZ_KB RSS_KB _ _ _ _ _ <<< $(ps -p $PID -o pid,ppid,%cpu,%mem,vsz,rss,stat,start,time,comm,args --no-headers 2>/dev/null | head -1)
      RSS_MB=$(echo "scale=1; ${RSS_KB:-0}/1024" | bc 2>/dev/null || echo 0)
      VSZ_MB=$(echo "scale=1; ${VSZ_KB:-0}/1024" | bc 2>/dev/null || echo 0)
      THREADS=$(cat /proc/${PID}/status 2>/dev/null | grep Threads | awk '{print $2}')
    fi

    # iperf results (written by run_iperf_ramp.sh if running)
    IPERF_DL=""; IPERF_UL=""; IPERF_TGT=""
    IPERF_FILE="$COLLECT_DIR/iperf_ue${i}.csv"
    if [ -f "$IPERF_FILE" ]; then
      LAST=$(tail -1 "$IPERF_FILE")
      IPERF_DL=$(echo "$LAST" | cut -d, -f3)
      IPERF_UL=$(echo "$LAST" | cut -d, -f4)
      IPERF_TGT=$(echo "$LAST" | cut -d, -f2)
    fi

    echo "$TS,$HOST_ID,$i,$NS,$IP,\
${SNR},${RSRP},${CFO},\
${DL_MCS},${DL_PRB},${DL_TBS},\
${UL_MCS},${UL_PRB},${UL_TBS},\
${TA},${PCI},${PRB_CELL},\
${PID},${RSS_MB},${VSZ_MB},${CPU_PCT},${THREADS},\
${IPERF_DL},${IPERF_UL},${IPERF_TGT}" >> "$OUT"
  done

  sleep "$INTERVAL"
done

echo "[collect_rich_ue] Done: $OUT rows=$(wc -l < $OUT)"
