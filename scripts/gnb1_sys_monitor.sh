#!/bin/bash
# gnb1_sys_monitor.sh
# Polls system + srsenb-level stats every 5s for a given duration (default 120s).
# Also snaps current per-slot metrics from all 50 CSV files.
# Runs on gnb1 (pc818).
# Output: /tmp/ran_collect/gnb1_sysmon.csv

DURATION=${1:-120}
INTERVAL=5
OUT=/tmp/ran_collect/gnb1_sysmon.csv
mkdir -p /tmp/ran_collect

echo "timestamp,cpu_total_pct,mem_used_pct,load1,load5,load15,\
rx_bytes_s,tx_bytes_s,\
total_srsenb_procs,total_ue_count,\
sum_dl_brate_bps,sum_ul_brate_bps,\
mean_proc_rss_kB,max_proc_rss_kB" > "$OUT"

IFACE=$(ip route | awk '/default/{print $5}' | head -1)
prev_rx=$(cat /sys/class/net/${IFACE}/statistics/rx_bytes 2>/dev/null || echo 0)
prev_tx=$(cat /sys/class/net/${IFACE}/statistics/tx_bytes 2>/dev/null || echo 0)

end_time=$(($(date +%s) + DURATION))

while [ "$(date +%s)" -lt "$end_time" ]; do
    TS=$(date -Iseconds)

    # CPU total %
    cpu_pct=$(top -bn1 | grep "Cpu(s)" | awk '{print $2+$4}')

    # Memory %
    mem_used_pct=$(free | awk '/Mem:/{printf "%.1f", ($3/$2)*100}')

    # Load averages
    read load1 load5 load15 rest < /proc/loadavg

    # Network throughput
    curr_rx=$(cat /sys/class/net/${IFACE}/statistics/rx_bytes 2>/dev/null || echo 0)
    curr_tx=$(cat /sys/class/net/${IFACE}/statistics/tx_bytes 2>/dev/null || echo 0)
    rx_s=$(( (curr_rx - prev_rx) / INTERVAL ))
    tx_s=$(( (curr_tx - prev_tx) / INTERVAL ))
    prev_rx=$curr_rx
    prev_tx=$curr_tx

    # Count srsenb procs and aggregate metrics from CSV files
    total_procs=$(pgrep -c srsenb 2>/dev/null || echo 0)
    total_ue=0
    sum_dl=0
    sum_ul=0
    rss_vals=""
    for f in /tmp/gnb1_ue*_metrics.csv; do
        [ -f "$f" ] || continue
        last=$(tail -1 "$f" 2>/dev/null)
        IFS=';' read -ra cols <<< "$last"
        if [ "${#cols[@]}" -ge 6 ]; then
            nof_ue="${cols[1]}"
            dl="${cols[2]}"
            ul="${cols[3]}"
            rss="${cols[5]}"
            total_ue=$(( total_ue + ${nof_ue:-0} ))
            sum_dl=$(awk "BEGIN{print $sum_dl + ${dl:-0}}")
            sum_ul=$(awk "BEGIN{print $sum_ul + ${ul:-0}}")
            [ -n "$rss" ] && rss_vals="$rss_vals $rss"
        fi
    done

    mean_rss="NA"
    max_rss="NA"
    if [ -n "$rss_vals" ]; then
        n=$(echo $rss_vals | wc -w)
        sum_rss=$(echo $rss_vals | tr ' ' '+' | bc 2>/dev/null || echo 0)
        mean_rss=$(awk "BEGIN{printf \"%.0f\", $sum_rss/$n}")
        max_rss=$(echo $rss_vals | tr ' ' '\n' | sort -g | tail -1)
    fi

    echo "$TS,$cpu_pct,$mem_used_pct,$load1,$load5,$load15,\
$rx_s,$tx_s,\
$total_procs,$total_ue,\
$sum_dl,$sum_ul,\
$mean_rss,$max_rss" >> "$OUT"

    sleep $INTERVAL
done

echo "[gnb1_sys_monitor] Done: $OUT"
wc -l "$OUT"
