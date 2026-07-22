#!/bin/bash
# collect_100s.sh — collect system + gNB metrics for 100 seconds
# Run ONCE on each node at the same time.
# Writes to /tmp/ran_collect/
#
# Usage: bash collect_100s.sh <node_role> <gnb_start_ue> <gnb_end_ue>
#   node_role: gnb1 | gnb2 | uehost1 | uehost2 | core
#   gnb_start_ue, gnb_end_ue: only used if node_role=gnb1 or gnb2

ROLE=${1:-uehost1}
GNB_START=${2:-1}
GNB_END=${3:-50}
DURATION=100
INTERVAL=2
COLLECT_DIR=/tmp/ran_collect
mkdir -p "$COLLECT_DIR"
HOSTNAME_SHORT=$(hostname | cut -d. -f1)

SYS_OUT="$COLLECT_DIR/sys_${ROLE}.csv"
GNB_OUT="$COLLECT_DIR/gnb_${ROLE}.csv"

# ── System metrics header ────────────────────────────────────
SYS_HDR="timestamp,role,hostname,cpu_pct,cpu_user,cpu_sys,cpu_iowait,\
cpu_freq_mhz,num_cpus,mem_used_mb,mem_total_mb,mem_free_mb,mem_cache_mb,\
load1,load5,load15,running_procs,total_procs,\
temp_c,irq_count,ctxt_count,rx_bytes,tx_bytes,\
srsenb_count,srsue_count,power_w"
echo "$SYS_HDR" > "$SYS_OUT"

# ── gNB metrics header ───────────────────────────────────────
if [ "$ROLE" = "gnb1" ] || [ "$ROLE" = "gnb2" ]; then
  GNB_HDR="timestamp,gnb_id,ue_slot,nof_ue,dl_brate_mbps,ul_brate_mbps,\
dl_nof_ok,dl_nof_nok,ul_nof_ok,ul_nof_nok,phr,last_ta,sys_load"
  echo "$GNB_HDR" > "$GNB_OUT"
fi

# ── Network interface ────────────────────────────────────────
IFACE=$(ip route 2>/dev/null | grep '^default' | awk '{print $5}' | head -1)
[ -z "$IFACE" ] && IFACE=$(ip link | awk -F': ' '/state UP/{print $2}' | grep -v lo | head -1)

echo "[collect_100s] role=$ROLE hostname=$HOSTNAME_SHORT iface=$IFACE duration=${DURATION}s interval=${INTERVAL}s"

PREV_IRQ=0; PREV_CTXT=0; PREV_RX=0; PREV_TX=0
ELAPSED=0

while [ $ELAPSED -lt $DURATION ]; do
  TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  T1=$(date +%s%N)

  # ── CPU (two snapshots 1s apart) ──────────────────────────
  read -r _ cu1 cn1 cs1 ci1 cw1 irq1 sirq1 st1 _ < /proc/stat
  sleep 1
  read -r _ cu2 cn2 cs2 ci2 cw2 irq2 sirq2 st2 _ < /proc/stat
  dt=$(( (cu2+cn2+cs2+ci2+cw2+irq2+sirq2+st2) - (cu1+cn1+cs1+ci1+cw1+irq1+sirq1+st1) ))
  di=$(( ci2 - ci1 ))
  CPU_TOT=0; CPU_USR=0; CPU_SYS=0; CPU_WAIT=0
  if [ $dt -gt 0 ]; then
    CPU_TOT=$(echo "scale=1; 100*($dt-$di)/$dt" | bc)
    CPU_USR=$(echo "scale=1; 100*$((cu2-cu1))/$dt" | bc)
    CPU_SYS=$(echo "scale=1; 100*$((cs2-cs1))/$dt" | bc)
    CPU_WAIT=$(echo "scale=1; 100*$((cw2-cw1))/$dt" | bc)
  fi

  # ── CPU frequency ─────────────────────────────────────────
  CPU_FREQ=$(awk '{s+=$1;n++}END{if(n>0)printf "%.0f",s/n/1000;else print "N/A"}' \
    /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null || echo "N/A")
  NUM_CPU=$(nproc)

  # ── Memory ────────────────────────────────────────────────
  MEM_TOT=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  MEM_FREE=$(awk '/MemFree/{print int($2/1024)}' /proc/meminfo)
  MEM_CACHE=$(awk '/^Cached/{print int($2/1024)}' /proc/meminfo | head -1)
  MEM_USED=$((MEM_TOT-MEM_FREE-MEM_CACHE))

  # ── Load ──────────────────────────────────────────────────
  read -r L1 L5 L15 PROCS _ < /proc/loadavg
  RUN_P=$(echo "$PROCS" | cut -d/ -f1)
  TOT_P=$(echo "$PROCS" | cut -d/ -f2)

  # ── Temperature ───────────────────────────────────────────
  TEMP=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0)
  TEMP=$(echo "scale=1; $TEMP/1000" | bc 2>/dev/null || echo "N/A")

  # ── IRQ + context switches ────────────────────────────────
  CUR_IRQ=$(awk '/^intr /{print $2}' /proc/stat)
  CUR_CTXT=$(awk '/^ctxt /{print $2}' /proc/stat)

  # ── Network bytes ─────────────────────────────────────────
  CUR_RX=$(cat /sys/class/net/${IFACE}/statistics/rx_bytes 2>/dev/null || echo 0)
  CUR_TX=$(cat /sys/class/net/${IFACE}/statistics/tx_bytes 2>/dev/null || echo 0)

  # ── Power (RAPL) ──────────────────────────────────────────
  POWER="N/A"
  RAPL=/sys/class/powercap/intel-rapl:0/energy_uj
  if [ -f "$RAPL" ]; then
    E1=$(cat "$RAPL"); sleep 0.5; E2=$(cat "$RAPL")
    POWER=$(echo "scale=2; ($E2-$E1)/500000" | bc 2>/dev/null || echo "N/A")
  fi

  # ── Process counts ────────────────────────────────────────
  ENB=$(pgrep -c srsenb 2>/dev/null || echo 0)
  UE=$(pgrep -c srsue 2>/dev/null || echo 0)

  echo "$TS,$ROLE,$HOSTNAME_SHORT,$CPU_TOT,$CPU_USR,$CPU_SYS,$CPU_WAIT,$CPU_FREQ,$NUM_CPU,$MEM_USED,$MEM_TOT,$MEM_FREE,$MEM_CACHE,$L1,$L5,$L15,$RUN_P,$TOT_P,$TEMP,$CUR_IRQ,$CUR_CTXT,$CUR_RX,$CUR_TX,$ENB,$UE,$POWER" >> "$SYS_OUT"

  # ── gNB slot metrics (latest line from each srsenb CSV) ───
  if [ "$ROLE" = "gnb1" ] || [ "$ROLE" = "gnb2" ]; then
    for i in $(seq $GNB_START $GNB_END); do
      MFILE="/tmp/${ROLE}_ue${i}_metrics.csv"
      [ ! -f "$MFILE" ] && continue
      LINE=$(tail -1 "$MFILE" 2>/dev/null)
      # skip header
      echo "$LINE" | grep -qE '^[0-9]' || continue
      IFS=';' read -r _ts NOF_UE DL_BR UL_BR DL_OK DL_NOK UL_OK UL_NOK DS US PHR TA SYSLOAD <<< "$LINE"
      DL_M=$(echo "scale=4; ${DL_BR:-0}/1000000" | bc 2>/dev/null || echo 0)
      UL_M=$(echo "scale=4; ${UL_BR:-0}/1000000" | bc 2>/dev/null || echo 0)
      echo "$TS,$ROLE,$i,${NOF_UE:-0},$DL_M,$UL_M,${DL_OK:-0},${DL_NOK:-0},${UL_OK:-0},${UL_NOK:-0},${PHR:-0},${TA:-0},${SYSLOAD:-0}" >> "$GNB_OUT"
    done
  fi

  T2=$(date +%s%N)
  SLEEP_REMAINING=$(echo "scale=3; $INTERVAL - ($T2-$T1)/1000000000" | bc 2>/dev/null || echo 0)
  SLEEP_REMAINING=$(echo "$SLEEP_REMAINING" | awk '{if($1>0.1) print $1; else print "0.1"}')
  sleep $SLEEP_REMAINING
  ELAPSED=$((ELAPSED+INTERVAL))
done

echo "[collect_100s] Done: $SYS_OUT ($(wc -l < $SYS_OUT) rows)"
[ -f "$GNB_OUT" ] && echo "[collect_100s] gNB: $GNB_OUT ($(wc -l < $GNB_OUT) rows)"
