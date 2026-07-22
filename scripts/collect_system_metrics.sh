#!/bin/bash
# ============================================================
# collect_system_metrics.sh
# Run on ANY node (gnb1/gnb2/uehost1/uehost2/core).
# Samples CPU %, freq, RAM, load, temp, IRQ rate, IPC, power
# every INTERVAL seconds and appends to COLLECT_DIR/system_metrics.csv
#
# Usage: bash collect_system_metrics.sh [interval_sec] [duration_sec]
#   e.g. bash collect_system_metrics.sh 5 3600
# ============================================================
set -euo pipefail

INTERVAL=${1:-5}
DURATION=${2:-7200}   # 2 hours default
COLLECT_DIR=/tmp/ran_collect
mkdir -p "$COLLECT_DIR"
OUT="$COLLECT_DIR/system_metrics.csv"
HOSTNAME_SHORT=$(hostname | cut -d. -f1)

# ── header ──────────────────────────────────────────────────
HEADER="timestamp,hostname,cpu_pct,cpu_freq_mhz,mem_used_mb,mem_total_mb,\
mem_free_mb,mem_cache_mb,load1,load5,load15,\
num_cpus,running_procs,total_procs,\
temp_c,irq_rate,ctxt_rate,ipc,\
rx_bytes_s,tx_bytes_s,\
srsenb_count,srsue_count,\
cpu_user_pct,cpu_sys_pct,cpu_iowait_pct,cpu_steal_pct,\
power_w,phase"

if [ ! -f "$OUT" ]; then
    echo "$HEADER" > "$OUT"
fi

# ── helpers ─────────────────────────────────────────────────
get_temp() {
    # Try multiple sources
    local t
    t=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo "")
    if [ -n "$t" ]; then echo "$(echo "scale=1; $t/1000" | bc)"; return; fi
    t=$(sensors 2>/dev/null | grep -oP 'Package id 0:\s+\+\K[0-9.]+' | head -1)
    [ -n "$t" ] && echo "$t" || echo "N/A"
}

get_ipc() {
    # Use perf stat for 0.5s sample if available
    if command -v perf &>/dev/null; then
        perf stat -e instructions,cycles -a sleep 0.5 2>&1 \
          | awk '/insn per cycle/ {print $NF}' | head -1
    else
        echo "N/A"
    fi
}

get_power() {
    # RAPL energy counter (Intel)
    local energy_file="/sys/class/powercap/intel-rapl:0/energy_uj"
    if [ -f "$energy_file" ]; then
        local e1 e2
        e1=$(cat "$energy_file" 2>/dev/null || echo 0)
        sleep 1
        e2=$(cat "$energy_file" 2>/dev/null || echo 0)
        echo "scale=2; ($e2 - $e1) / 1000000" | bc
    else
        echo "N/A"
    fi
}

get_net_rate() {
    local iface
    iface=$(ip route | grep '^default' | awk '{print $5}' | head -1)
    [ -z "$iface" ] && iface=$(ip link | grep 'state UP' | grep -v lo | awk -F: '{print $2}' | tr -d ' ' | head -1)
    local rx1 tx1 rx2 tx2
    rx1=$(cat /sys/class/net/${iface}/statistics/rx_bytes 2>/dev/null || echo 0)
    tx1=$(cat /sys/class/net/${iface}/statistics/tx_bytes 2>/dev/null || echo 0)
    sleep 1
    rx2=$(cat /sys/class/net/${iface}/statistics/rx_bytes 2>/dev/null || echo 0)
    tx2=$(cat /sys/class/net/${iface}/statistics/tx_bytes 2>/dev/null || echo 0)
    echo "$((rx2-rx1)),$((tx2-tx1))"
}

# ── main loop ───────────────────────────────────────────────
START=$(date +%s)
PREV_IRQ=0
PREV_CTXT=0
PHASE="baseline"

echo "[collect_system] Starting on $HOSTNAME_SHORT — interval=${INTERVAL}s duration=${DURATION}s"

while true; do
    NOW=$(date +%s)
    [ $((NOW - START)) -ge $DURATION ] && break
    TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Read phase file if exists
    [ -f /tmp/ran_collect/phase.txt ] && PHASE=$(cat /tmp/ran_collect/phase.txt)

    # CPU via /proc/stat (two samples)
    read -r _ user1 nice1 sys1 idle1 iowait1 irq1 softirq1 steal1 _ < /proc/stat
    sleep 1
    read -r _ user2 nice2 sys2 idle2 iowait2 irq2 softirq2 steal2 _ < /proc/stat
    total1=$((user1+nice1+sys1+idle1+iowait1+irq1+softirq1+steal1))
    total2=$((user2+nice2+sys2+idle2+iowait2+irq2+softirq2+steal2))
    dtotal=$((total2-total1))
    didle=$((idle2-idle1))
    duser=$((user2-user1))
    dsys=$((sys2-sys1))
    diowait=$((iowait2-iowait1))
    dsteal=$((steal2-steal1))
    CPU_PCT=0; CPU_USER=0; CPU_SYS=0; CPU_IOWAIT=0; CPU_STEAL=0
    if [ $dtotal -gt 0 ]; then
        CPU_PCT=$(echo "scale=1; 100*(${dtotal}-${didle})/${dtotal}" | bc)
        CPU_USER=$(echo "scale=1; 100*${duser}/${dtotal}" | bc)
        CPU_SYS=$(echo "scale=1; 100*${dsys}/${dtotal}" | bc)
        CPU_IOWAIT=$(echo "scale=1; 100*${diowait}/${dtotal}" | bc)
        CPU_STEAL=$(echo "scale=1; 100*${dsteal}/${dtotal}" | bc)
    fi

    # CPU frequency (MHz) — average across all cores
    CPU_FREQ=$(awk '{sum+=$1; n++} END {if(n>0) printf "%.0f", sum/n/1000; else print "N/A"}' \
               /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null || echo "N/A")

    # Memory
    MEM_TOTAL=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    MEM_FREE=$(awk '/MemFree/ {print int($2/1024)}' /proc/meminfo)
    MEM_CACHE=$(awk '/^Cached/ {print int($2/1024)}' /proc/meminfo | head -1)
    MEM_USED=$((MEM_TOTAL - MEM_FREE - MEM_CACHE))

    # Load average
    read -r LOAD1 LOAD5 LOAD15 PROCS _ < /proc/loadavg
    RUN_PROCS=$(echo "$PROCS" | cut -d/ -f1)
    TOT_PROCS=$(echo "$PROCS" | cut -d/ -f2)

    # CPU count
    NUM_CPUS=$(nproc)

    # IRQ and context switch rates
    CUR_IRQ=$(awk '/^intr / {print $2}' /proc/stat)
    CUR_CTXT=$(awk '/^ctxt / {print $2}' /proc/stat)
    IRQ_RATE=0; CTXT_RATE=0
    [ "$PREV_IRQ" -gt 0 ] && IRQ_RATE=$((CUR_IRQ - PREV_IRQ))
    [ "$PREV_CTXT" -gt 0 ] && CTXT_RATE=$((CUR_CTXT - PREV_CTXT))
    PREV_IRQ=$CUR_IRQ; PREV_CTXT=$CUR_CTXT

    # Temperature
    TEMP=$(get_temp)

    # Network rates (run in parallel with sleep already in CPU)
    NET_RATES=$(get_net_rate)
    RX_RATE=$(echo "$NET_RATES" | cut -d, -f1)
    TX_RATE=$(echo "$NET_RATES" | cut -d, -f2)

    # IPC
    IPC=$(get_ipc)

    # Power
    POWER=$(get_power)

    # Process counts
    ENB_COUNT=$(pgrep -c srsenb 2>/dev/null || echo 0)
    UE_COUNT=$(pgrep -c srsue 2>/dev/null || echo 0)

    echo "${TS},${HOSTNAME_SHORT},${CPU_PCT},${CPU_FREQ},${MEM_USED},${MEM_TOTAL},${MEM_FREE},${MEM_CACHE},${LOAD1},${LOAD5},${LOAD15},${NUM_CPUS},${RUN_PROCS},${TOT_PROCS},${TEMP},${IRQ_RATE},${CTXT_RATE},${IPC},${RX_RATE},${TX_RATE},${ENB_COUNT},${UE_COUNT},${CPU_USER},${CPU_SYS},${CPU_IOWAIT},${CPU_STEAL},${POWER},${PHASE}" >> "$OUT"

    sleep $((INTERVAL - 2))   # account for ~2s of measurements above
done

echo "[collect_system] Done. Output: $OUT ($(wc -l < $OUT) rows)"
