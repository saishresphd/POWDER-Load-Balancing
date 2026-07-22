#!/bin/bash
# collect_rich_gnb1.sh
# Parses gnb1 log files for each UE slot (ue1..ue50):
#   PUCCH: snr, cqi, ta
#   PUSCH: snr_ul, mcs_ul, tbs_ul, ta_ul
#   PDSCH: nof_prb_dl, nof_re_dl, mcs_dl, tbs_dl
# Also reads per-slot srsenb metrics CSV for: dl_brate, ul_brate, proc_rmem_kB, proc_vmem_kB, cpu_cores
# Output: /tmp/ran_collect/gnb1_rich_metrics.csv

# No pipefail/errexit — large log file greps with head cause SIGPIPE
set +e
set -uo pipefail
set +o pipefail
LOGDIR=/tmp/gnb1_logs
METDIR=/tmp
OUT=/tmp/ran_collect/gnb1_rich_metrics.csv
mkdir -p /tmp/ran_collect

# Header
echo "ue_id,timestamp,\
pucch_snr_db,pucch_cqi,pucch_ta_us,\
pusch_snr_db,pusch_mcs,pusch_tbs,pusch_ta_us,\
pdsch_nof_prb,pdsch_nof_re,pdsch_mcs,pdsch_tbs,\
dl_brate_bps,ul_brate_bps,\
proc_rss_kB,proc_vmem_kB,sys_mem_pct,sys_load,thread_count,\
cpu_max,cpu_mean,\
prb_util_pct" > "$OUT"

for i in $(seq 1 50); do
    LOGFILE="$LOGDIR/ue${i}.log"
    METRICSFILE="$METDIR/gnb1_ue${i}_metrics.csv"

    # Skip if log doesn't exist
    if [ ! -f "$LOGFILE" ]; then
        continue
    fi

    # --- Parse PUCCH (last valid line with finite snr and cqi) ---
    pucch_line=$(grep "PUCCH:" "$LOGFILE" 2>/dev/null | grep -v "snr=-inf" | grep "cqi=" | tail -1)
    pucch_snr="NA"
    pucch_cqi="NA"
    pucch_ta="NA"
    if [ -n "$pucch_line" ]; then
        pucch_snr=$(echo "$pucch_line" | grep -oP 'snr=\K[0-9.-]+' | head -1)
        pucch_cqi=$(echo "$pucch_line" | grep -oP 'cqi=\K[0-9]+' | head -1)
        pucch_ta=$(echo "$pucch_line" | grep -oP 'ta=\K[0-9.-]+' | head -1)
        ts=$(echo "$pucch_line" | grep -oP '^\S+' | head -1)
    fi

    # --- Parse PUSCH (last line) ---
    pusch_line=$(grep "PUSCH:" "$LOGFILE" 2>/dev/null | grep "crc=OK" | tail -1)
    pusch_snr="NA"
    pusch_mcs="NA"
    pusch_tbs="NA"
    pusch_ta="NA"
    if [ -n "$pusch_line" ]; then
        pusch_snr=$(echo "$pusch_line" | grep -oP 'snr=\K[0-9.-]+' | head -1)
        pusch_mcs=$(echo "$pusch_line" | grep -oP 'mod=\K[0-9]+' | head -1)
        pusch_tbs=$(echo "$pusch_line" | grep -oP 'tbs=\K[0-9]+' | head -1)
        pusch_ta=$(echo "$pusch_line" | grep -oP 'ta=\K[0-9.-]+' | head -1)
        [ -z "$ts" ] && ts=$(echo "$pusch_line" | grep -oP '^\S+' | head -1)
    fi

    # --- Parse PDSCH (last line for this UE rnti, not broadcast) ---
    # Identify RNTI for this UE from log (grep -m1 avoids SIGPIPE vs head)
    ue_rnti=$(grep -m1 -oP 'rnti=0x[0-9a-f]+' "$LOGFILE" 2>/dev/null | grep -v "^rnti=0x2$" | head -1 || true)
    pdsch_nof_prb="NA"
    pdsch_nof_re="NA"
    pdsch_mcs="NA"
    pdsch_tbs="NA"
    if [ -n "$ue_rnti" ]; then
        pdsch_line=$(grep "PDSCH:.*${ue_rnti}" "$LOGFILE" 2>/dev/null | tail -1 || true)
        if [ -n "$pdsch_line" ]; then
            pdsch_nof_prb=$(echo "$pdsch_line" | grep -oP 'nof_prb=\K[0-9]+' | head -1)
            pdsch_nof_re=$(echo "$pdsch_line" | grep -oP 'nof_re=\K[0-9]+' | head -1)
            pdsch_mcs=$(echo "$pdsch_line" | grep -oP 'mod=\{?\K[0-9]+' | head -1)
            pdsch_tbs=$(echo "$pdsch_line" | grep -oP 'tbs=\{?\K[0-9]+' | head -1)
        fi
    fi

    # PRB utilization (last nof_prb as % of 50)
    prb_util="NA"
    if [ "$pdsch_nof_prb" != "NA" ] && [ -n "$pdsch_nof_prb" ]; then
        prb_util=$(awk "BEGIN {printf \"%.2f\", ($pdsch_nof_prb/50.0)*100}")
    fi

    # --- Parse srsenb metrics CSV ---
    dl_brate="NA"
    ul_brate="NA"
    proc_rss="NA"
    proc_vmem="NA"
    sys_mem="NA"
    sys_load="NA"
    thread_count="NA"
    cpu_max="NA"
    cpu_mean="NA"
    if [ -f "$METRICSFILE" ]; then
        # Last data row (skip header)
        last_row=$(tail -1 "$METRICSFILE")
        IFS=';' read -ra cols <<< "$last_row"
        # cols: time;nof_ue;dl_brate;ul_brate;proc_rmem;proc_rmem_kB;proc_vmem_kB;sys_mem;system_load;thread_count;cpu_0..cpu_31
        if [ "${#cols[@]}" -ge 10 ]; then
            dl_brate="${cols[2]}"
            ul_brate="${cols[3]}"
            proc_rss="${cols[5]}"
            proc_vmem="${cols[6]}"
            sys_mem="${cols[7]}"
            sys_load="${cols[8]}"
            thread_count="${cols[9]}"
            # CPU cols start at index 10
            cpu_vals=""
            for j in $(seq 10 $((${#cols[@]}-1))); do
                v="${cols[$j]}"
                [ -n "$v" ] && cpu_vals="$cpu_vals $v"
            done
            if [ -n "$cpu_vals" ]; then
                cpu_max=$(echo "$cpu_vals" | tr ' ' '\n' | sort -g | tail -1)
                n=$(echo "$cpu_vals" | wc -w)
                s=$(echo "$cpu_vals" | tr ' ' '+' | bc -l 2>/dev/null || echo 0)
                cpu_mean=$(awk "BEGIN {printf \"%.2f\", $s/$n}")
            fi
        fi
    fi

    # Use current timestamp if no log timestamp found
    [ -z "${ts:-}" ] && ts=$(date -Iseconds)

    echo "$i,$ts,\
$pucch_snr,$pucch_cqi,$pucch_ta,\
$pusch_snr,$pusch_mcs,$pusch_tbs,$pusch_ta,\
$pdsch_nof_prb,$pdsch_nof_re,$pdsch_mcs,$pdsch_tbs,\
$dl_brate,$ul_brate,\
$proc_rss,$proc_vmem,$sys_mem,$sys_load,$thread_count,\
$cpu_max,$cpu_mean,\
$prb_util" >> "$OUT"
done

echo "[collect_rich_gnb1] Done: $OUT"
wc -l "$OUT"
