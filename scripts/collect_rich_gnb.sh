#!/bin/bash
# collect_rich_gnb.sh — Run on gnb1 (pc818)
# Collects 100s of:
#   1. Full srsenb metrics CSV (nof_ue, brate, proc mem, per-core CPU)
#   2. Key RAN measurements parsed from gnb log (SNR, CQI, MCS, PRB, TA)
# Output: /tmp/ran_collect/gnb_rich_{gnb_id}.csv

GNB_ID=${1:-gnb1}
START_UE=${2:-1}
END_UE=${3:-50}
DURATION=${4:-100}
INTERVAL=${5:-2}
COLLECT_DIR=/tmp/ran_collect
mkdir -p "$COLLECT_DIR"
OUT="$COLLECT_DIR/gnb_rich_${GNB_ID}.csv"

# Full metrics header from srsenb CSV
# time;nof_ue;dl_brate;ul_brate;proc_rmem;proc_rmem_kB;proc_vmem_kB;
# sys_mem;system_load;thread_count;cpu_0..cpu_31
HDR="timestamp,gnb_id,ue_slot,\
nof_ue,dl_brate_bps,ul_brate_bps,dl_brate_mbps,ul_brate_mbps,\
proc_rmem_mb,proc_rmem_kB,proc_vmem_kB,\
sys_mem_pct,system_load,thread_count,\
cpu_0,cpu_1,cpu_2,cpu_3,cpu_4,cpu_5,cpu_6,cpu_7,\
cpu_8,cpu_9,cpu_10,cpu_11,cpu_12,cpu_13,cpu_14,cpu_15,\
cpu_16,cpu_17,cpu_18,cpu_19,cpu_20,cpu_21,cpu_22,cpu_23,\
cpu_24,cpu_25,cpu_26,cpu_27,cpu_28,cpu_29,cpu_30,cpu_31,\
ul_snr_db,ul_epre_dbfs,ul_mcs,ul_nof_prb,ul_ta_us,\
dl_mcs,dl_nof_prb,cqi,pucch_snr_db,\
dl_nof_ok,dl_nof_nok,ul_nof_ok,ul_nof_nok,phr,last_ta"

echo "$HDR" > "$OUT"

echo "[collect_rich_gnb] $GNB_ID UE${START_UE}-${END_UE} duration=${DURATION}s"
START=$(date +%s)
ELAPSED=0

while [ $ELAPSED -lt $DURATION ]; do
  TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  NOW=$(date +%s)
  ELAPSED=$((NOW - START))

  for i in $(seq $START_UE $END_UE); do
    MFILE="/tmp/${GNB_ID}_ue${i}_metrics.csv"
    LFILE="/tmp/${GNB_ID}_ue${i}.log"
    [ ! -f "$MFILE" ] && continue

    # Get latest line from srsenb metrics CSV
    LINE=$(tail -1 "$MFILE" 2>/dev/null)
    # Skip header or empty
    echo "$LINE" | grep -qE '^[0-9]' || continue

    # Parse: time;nof_ue;dl_brate;ul_brate;proc_rmem;proc_rmem_kB;proc_vmem_kB;sys_mem;system_load;thread_count;cpu_0..cpu_31
    IFS=';' read -r TTI NOF_UE DL_BR UL_BR PROC_RMEM PROC_RMEM_KB PROC_VMK SYS_MEM SYS_LOAD THREADS \
      C0 C1 C2 C3 C4 C5 C6 C7 C8 C9 C10 C11 C12 C13 C14 C15 \
      C16 C17 C18 C19 C20 C21 C22 C23 C24 C25 C26 C27 C28 C29 C30 C31 <<< "$LINE"

    DL_MBPS=$(echo "scale=4; ${DL_BR:-0}/1000000" | bc 2>/dev/null || echo 0)
    UL_MBPS=$(echo "scale=4; ${UL_BR:-0}/1000000" | bc 2>/dev/null || echo 0)
    PROC_RMEM_MB=$(echo "scale=2; ${PROC_RMEM:-0}*1000" | bc 2>/dev/null || echo 0)

    # Parse latest RAN measurements from gnb log (last 200 lines)
    UL_SNR=""; UL_EPRE=""; UL_MCS=""; UL_PRB=""; UL_TA=""
    DL_MCS=""; DL_PRB=""; CQI=""; PUCCH_SNR=""
    DL_OK=""; DL_NOK=""; UL_OK=""; UL_NOK=""; PHR=""; LAST_TA=""

    if [ -f "$LFILE" ]; then
      RECENT=$(tail -500 "$LFILE" 2>/dev/null)

      # PUSCH: snr, epre, mcs, rb (prb), ta
      PUSCH=$(echo "$RECENT" | grep 'PUSCH:' | tail -1)
      if [ -n "$PUSCH" ]; then
        UL_SNR=$(echo "$PUSCH" | grep -oE 'snr=[0-9.-]+' | tail -1 | cut -d= -f2)
        UL_EPRE=$(echo "$PUSCH" | grep -oE 'epre=[0-9.-]+' | tail -1 | cut -d= -f2)
        UL_MCS=$(echo "$PUSCH" | grep -oE 'mod=[0-9]+' | tail -1 | cut -d= -f2)
        UL_PRB=$(echo "$PUSCH" | grep -oE 'nof_prb=[0-9]+\|rb=\([0-9,]+\)' | tail -1)
        UL_PRB=$(echo "$PUSCH" | grep -oE 'nof_re=[0-9]+' | tail -1 | cut -d= -f2)
        UL_TA=$(echo "$PUSCH" | grep -oE 'ta=[0-9.-]+' | tail -1 | cut -d= -f2)
      fi

      # PDSCH: mcs, nof_prb
      PDSCH=$(echo "$RECENT" | grep 'PDSCH:' | grep 'rnti=0x4' | tail -1)
      if [ -n "$PDSCH" ]; then
        DL_MCS=$(echo "$PDSCH" | grep -oE 'mod=\{[0-9]+\}' | tail -1 | grep -oE '[0-9]+')
        DL_PRB=$(echo "$PDSCH" | grep -oE 'nof_prb=[0-9]+' | tail -1 | cut -d= -f2)
      fi

      # PUCCH CQI: cqi=N
      CQI_LINE=$(echo "$RECENT" | grep 'PUCCH:' | grep 'cqi=' | grep -v 'cqi=0' | tail -1)
      [ -n "$CQI_LINE" ] && CQI=$(echo "$CQI_LINE" | grep -oE 'cqi=[0-9]+' | tail -1 | cut -d= -f2)

      # PUCCH SNR
      PUCCH_LINE=$(echo "$RECENT" | grep 'PUCCH:' | grep -v 'snr=-inf' | tail -1)
      [ -n "$PUCCH_LINE" ] && PUCCH_SNR=$(echo "$PUCCH_LINE" | grep -oE 'snr=[0-9.-]+' | tail -1 | cut -d= -f2)
    fi

    # Also grab dl_nof_ok/nok from metrics CSV (already parsed in old gnb_gnb1.csv format)
    # These are in a different srsenb build — check second metric file format
    OLD_MFILE="/tmp/${GNB_ID}_ue${i}_metrics.csv"
    if [ -f "$OLD_MFILE" ]; then
      OLD_LINE=$(tail -1 "$OLD_MFILE" 2>/dev/null)
      # Old format: timestamp;nof_ue;dl_brate;ul_brate;dl_nof_ok;dl_nof_nok;ul_nof_ok;ul_nof_nok;...;phr;last_ta;sys_load
      # But this build has different format — use what we have
      :
    fi

    echo "$TS,$GNB_ID,$i,\
${NOF_UE:-0},${DL_BR:-0},${UL_BR:-0},${DL_MBPS},${UL_MBPS},\
${PROC_RMEM_MB},${PROC_RMEM_KB:-0},${PROC_VMK:-0},\
${SYS_MEM:-0},${SYS_LOAD:-0},${THREADS:-0},\
${C0:-0},${C1:-0},${C2:-0},${C3:-0},${C4:-0},${C5:-0},${C6:-0},${C7:-0},\
${C8:-0},${C9:-0},${C10:-0},${C11:-0},${C12:-0},${C13:-0},${C14:-0},${C15:-0},\
${C16:-0},${C17:-0},${C18:-0},${C19:-0},${C20:-0},${C21:-0},${C22:-0},${C23:-0},\
${C24:-0},${C25:-0},${C26:-0},${C27:-0},${C28:-0},${C29:-0},${C30:-0},${C31:-0},\
${UL_SNR},${UL_EPRE},${UL_MCS},${UL_PRB},${UL_TA},\
${DL_MCS},${DL_PRB},${CQI},${PUCCH_SNR},\
${DL_OK},${DL_NOK},${UL_OK},${UL_NOK},${PHR},${LAST_TA}" >> "$OUT"
  done

  sleep "$INTERVAL"
done

echo "[collect_rich_gnb] Done: $OUT rows=$(wc -l < $OUT)"
