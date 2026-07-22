#!/bin/bash
# collect_ue_rsrp_snr.sh
# Parses srsUE stdout logs on uehost1 for:
#   - RSRP (dBm), SNR (dB), PCI, EARFCN from MEAS/signal lines
#   - Attach IP, c-rnti, PRB count
#   - Process RSS/VSZ from /proc/<pid>/status
# Output: /tmp/ran_collect/ue_phy_metrics.csv

set +e
LOGDIR=/tmp/ue_logs
OUT=/tmp/ran_collect/ue_phy_metrics.csv
mkdir -p /tmp/ran_collect

echo "ue_id,ue_ip,c_rnti,pci,earfcn,prb_count,rsrp_dbm,snr_dl_db,pid,rss_kB,vsz_kB,threads" > "$OUT"

for i in $(seq 1 50); do
    LOGFILE="$LOGDIR/ue${i}_stdout.log"
    if [ ! -f "$LOGFILE" ]; then
        echo "$i,NA,NA,NA,NA,NA,NA,NA,NA,NA,NA,NA" >> "$OUT"
        continue
    fi

    # IP address
    ue_ip=$(grep "Network attach successful" "$LOGFILE" 2>/dev/null | grep -oP 'IP: \K[\d.]+' | tail -1)
    [ -z "$ue_ip" ] && ue_ip="NA"

    # c-rnti
    c_rnti=$(grep "Random Access Complete" "$LOGFILE" 2>/dev/null | grep -oP 'c-rnti=\K\S+' | tail -1)
    [ -z "$c_rnti" ] && c_rnti="NA"

    # PCI and EARFCN from "Found Cell" line
    pci=$(grep "Found Cell" "$LOGFILE" 2>/dev/null | grep -oP 'PCI=\K[0-9]+' | tail -1)
    [ -z "$pci" ] && pci="NA"
    earfcn=$(grep "Found Cell" "$LOGFILE" 2>/dev/null | grep -oP 'earfcn=\K[0-9]+' | tail -1)
    [ -z "$earfcn" ] && earfcn="NA"

    # PRB count
    prb=$(grep "Found Cell" "$LOGFILE" 2>/dev/null | grep -oP 'PRB=\K[0-9]+' | tail -1)
    [ -z "$prb" ] && prb="NA"

    # RSRP from MEAS lines (most recent valid value)
    rsrp=$(grep -oP 'rsrp=\K-?[0-9.]+' "$LOGFILE" 2>/dev/null | tail -1)
    [ -z "$rsrp" ] && rsrp="NA"

    # SNR DL — srsUE prints "SNR=XX.X dB" in cell search phase
    snr_dl=$(grep -oP 'SNR=\K[0-9.]+' "$LOGFILE" 2>/dev/null | tail -1)
    [ -z "$snr_dl" ] && snr_dl="NA"

    # Find PID of srsue process for this UE
    pid=$(pgrep -f "srsue /etc/srsue/ue${i}\.conf" 2>/dev/null | head -1)
    rss="NA"
    vsz="NA"
    threads="NA"
    if [ -n "$pid" ] && [ -f "/proc/$pid/status" ]; then
        rss=$(grep "^VmRSS:" /proc/$pid/status 2>/dev/null | awk '{print $2}')
        vsz=$(grep "^VmSize:" /proc/$pid/status 2>/dev/null | awk '{print $2}')
        threads=$(grep "^Threads:" /proc/$pid/status 2>/dev/null | awk '{print $2}')
    fi
    [ -z "$pid" ] && pid="NA"
    [ -z "$rss" ] && rss="NA"
    [ -z "$vsz" ] && vsz="NA"
    [ -z "$threads" ] && threads="NA"

    echo "$i,$ue_ip,$c_rnti,$pci,$earfcn,$prb,$rsrp,$snr_dl,$pid,$rss,$vsz,$threads" >> "$OUT"
done

echo "[collect_ue_rsrp_snr] Done: $OUT"
wc -l "$OUT"
