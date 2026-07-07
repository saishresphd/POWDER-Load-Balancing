#!/bin/bash
# ==========================================================================
#  collect_cpu_metrics.sh  — Collect CPU/system metrics during experiment
#  Run on ALL nodes simultaneously (core, gnb1, gnb2, uehost1, uehost2)
#  Output: /tmp/metrics_$(hostname)_$(date +%s).csv
# ==========================================================================

INTERVAL=1        # seconds between samples
DURATION=${1:-300}  # default 5 min, pass arg to override
OUTFILE=/tmp/metrics_$(hostname)_$(date +%s).csv
HOSTIP=$(hostname -I | awk '{print $1}')

echo "Collecting CPU metrics on $(hostname) ($HOSTIP) for ${DURATION}s → $OUTFILE"

# CSV header
echo "timestamp,hostname,cpu_total_pct,cpu_user_pct,cpu_sys_pct,cpu_idle_pct,\
cpu_iowait_pct,load_1m,load_5m,load_15m,\
mem_used_mb,mem_total_mb,mem_pct,\
net_rx_bps,net_tx_bps,proc_count,\
gnb_cpu_pct,srsue_cpu_pct,open5gs_cpu_pct" > $OUTFILE

# Track previous net counters for delta
IFACE=$(ip route | grep "^default\|10.10.1" | head -1 | awk '{print $NF}')
[ -z "$IFACE" ] && IFACE="enp6s0f3"
PREV_RX=0; PREV_TX=0

for s in $(seq 1 $DURATION); do
    TS=$(date +%s)
    
    # CPU via /proc/stat (delta)
    CPU1=$(grep "^cpu " /proc/stat)
    sleep $INTERVAL
    CPU2=$(grep "^cpu " /proc/stat)
    
    # Parse: user nice sys idle iowait irq softirq
    read -r _ u1 n1 s1 i1 w1 _ _ <<< "$CPU1"
    read -r _ u2 n2 s2 i2 w2 _ _ <<< "$CPU2"
    TOTAL=$(( (u2+n2+s2+i2+w2) - (u1+n1+s1+i1+w1) ))
    IDLE=$(( i2 - i1 ))
    IOWAIT=$(( w2 - w1 ))
    USER=$(( u2 - u1 ))
    SYS=$(( s2 - s1 ))
    
    if [ $TOTAL -gt 0 ]; then
        CPU_TOTAL=$(echo "scale=1; 100*(${TOTAL}-${IDLE})/${TOTAL}" | bc)
        CPU_USER=$(echo  "scale=1; 100*${USER}/${TOTAL}" | bc)
        CPU_SYS=$(echo   "scale=1; 100*${SYS}/${TOTAL}"  | bc)
        CPU_IDLE=$(echo  "scale=1; 100*${IDLE}/${TOTAL}" | bc)
        CPU_IOW=$(echo   "scale=1; 100*${IOWAIT}/${TOTAL}" | bc)
    else
        CPU_TOTAL=0; CPU_USER=0; CPU_SYS=0; CPU_IDLE=100; CPU_IOW=0
    fi
    
    # Load average
    read LOAD1 LOAD5 LOAD15 _ < /proc/loadavg
    
    # Memory
    MEM_TOTAL=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')
    MEM_FREE=$(grep MemAvailable /proc/meminfo | awk '{print int($2/1024)}')
    MEM_USED=$((MEM_TOTAL - MEM_FREE))
    MEM_PCT=$(echo "scale=1; 100*${MEM_USED}/${MEM_TOTAL}" | bc)
    
    # Network (bytes/sec delta)
    RX_NOW=$(cat /sys/class/net/${IFACE}/statistics/rx_bytes 2>/dev/null || echo 0)
    TX_NOW=$(cat /sys/class/net/${IFACE}/statistics/tx_bytes 2>/dev/null || echo 0)
    NET_RX=$(( RX_NOW - PREV_RX ))
    NET_TX=$(( TX_NOW - PREV_TX ))
    PREV_RX=$RX_NOW; PREV_TX=$TX_NOW
    
    # Process count
    PROCS=$(ls /proc | grep -c '^[0-9]')
    
    # Per-process CPU (srsRAN, Open5GS)
    GNB_CPU=$(ps aux | awk '/srsenb|srsgnb/{sum+=$3} END{printf "%.1f",sum}')
    UE_CPU=$(ps  aux | awk '/srsue/{sum+=$3} END{printf "%.1f",sum}')
    O5GS_CPU=$(ps aux | awk '/open5gs/{sum+=$3} END{printf "%.1f",sum}')
    
    echo "${TS},$(hostname),${CPU_TOTAL},${CPU_USER},${CPU_SYS},${CPU_IDLE},\
${CPU_IOW},${LOAD1},${LOAD5},${LOAD15},\
${MEM_USED},${MEM_TOTAL},${MEM_PCT},\
${NET_RX},${NET_TX},${PROCS},\
${GNB_CPU},${UE_CPU},${O5GS_CPU}" >> $OUTFILE
    
    # Print live summary every 10s
    if [ $((s % 10)) -eq 0 ]; then
        echo "  [$(date +%H:%M:%S)] CPU=${CPU_TOTAL}% load=${LOAD1} mem=${MEM_PCT}% gnb=${GNB_CPU}% ue=${UE_CPU}%"
    fi
done

echo "DONE. Metrics saved to $OUTFILE"
