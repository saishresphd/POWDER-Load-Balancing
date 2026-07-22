#!/bin/bash
# collect_power.sh
# Collects RAPL power (pkg0, pkg1, dram0, dram1) + cpufreq on a node.
# Samples every INTERVAL seconds for DURATION seconds, writes to OUT_CSV.
# Usage: sudo bash collect_power.sh [DURATION=120] [INTERVAL=2] [OUT=/tmp/ran_collect/power.csv]
#
# Requires: root (sudo) for intel-rapl energy_uj reads.

set -e

DURATION=${1:-120}
INTERVAL=${2:-2}
OUT_CSV=${3:-/tmp/ran_collect/power.csv}

RAPL_BASE="/sys/class/powercap"
CPUFREQ_BASE="/sys/devices/system/cpu"

# Check RAPL available
if [ ! -d "${RAPL_BASE}/intel-rapl:0" ]; then
    echo "ERROR: RAPL not available at ${RAPL_BASE}" >&2
    exit 1
fi

# Helper: read energy_uj (requires root)
read_uj() {
    local path="${RAPL_BASE}/${1}/energy_uj"
    if [ -f "$path" ]; then
        cat "$path" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# Helper: read cpufreq for cpu0 (representative)
read_freq_khz() {
    local path="${CPUFREQ_BASE}/cpu0/cpufreq/scaling_cur_freq"
    if [ -f "$path" ]; then
        cat "$path" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# Helper: read max_freq
read_maxfreq_khz() {
    local path="${CPUFREQ_BASE}/cpu0/cpufreq/cpuinfo_max_freq"
    if [ -f "$path" ]; then
        cat "$path" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# Write CSV header
echo "timestamp,elapsed_s,pkg0_power_W,pkg1_power_W,dram0_power_W,dram1_power_W,cpu0_freq_MHz,cpu_max_freq_MHz" > "$OUT_CSV"

echo "[collect_power] Starting: duration=${DURATION}s interval=${INTERVAL}s out=${OUT_CSV}"

START_TS=$(date +%s%N)   # nanoseconds

# First sample (baseline)
PREV_PKG0=$(read_uj "intel-rapl:0")
PREV_PKG1=$(read_uj "intel-rapl:1")
PREV_DRAM0=$(read_uj "intel-rapl:0:0")
PREV_DRAM1=$(read_uj "intel-rapl:1:0")
PREV_TIME_US=$(( $(date +%s%N) / 1000 ))

MAX_FREQ=$(read_maxfreq_khz)
MAX_FREQ_MHZ=$(echo "scale=1; $MAX_FREQ / 1000" | bc)

sleep "$INTERVAL"

ELAPSED=0
while [ "$ELAPSED" -lt "$DURATION" ]; do
    NOW_TIME_US=$(( $(date +%s%N) / 1000 ))
    DELTA_US=$(( NOW_TIME_US - PREV_TIME_US ))

    CUR_PKG0=$(read_uj "intel-rapl:0")
    CUR_PKG1=$(read_uj "intel-rapl:1")
    CUR_DRAM0=$(read_uj "intel-rapl:0:0")
    CUR_DRAM1=$(read_uj "intel-rapl:1:0")
    FREQ_KHZ=$(read_freq_khz)

    # Compute power in Watts: delta_uj / delta_us = watts
    PKG0_W=$(awk "BEGIN { printf \"%.2f\", ($CUR_PKG0 - $PREV_PKG0) / $DELTA_US }")
    PKG1_W=$(awk "BEGIN { printf \"%.2f\", ($CUR_PKG1 - $PREV_PKG1) / $DELTA_US }")
    DRAM0_W=$(awk "BEGIN { printf \"%.2f\", ($CUR_DRAM0 - $PREV_DRAM0) / $DELTA_US }")
    DRAM1_W=$(awk "BEGIN { printf \"%.2f\", ($CUR_DRAM1 - $PREV_DRAM1) / $DELTA_US }")
    FREQ_MHZ=$(awk "BEGIN { printf \"%.0f\", $FREQ_KHZ / 1000 }")

    TS=$(date -Iseconds)
    ELAPSED=$(( (NOW_TIME_US - START_TS / 1000) / 1000000 ))

    echo "${TS},${ELAPSED},${PKG0_W},${PKG1_W},${DRAM0_W},${DRAM1_W},${FREQ_MHZ},${MAX_FREQ_MHZ}" >> "$OUT_CSV"

    PREV_PKG0=$CUR_PKG0
    PREV_PKG1=$CUR_PKG1
    PREV_DRAM0=$CUR_DRAM0
    PREV_DRAM1=$CUR_DRAM1
    PREV_TIME_US=$NOW_TIME_US

    sleep "$INTERVAL"
done

echo "[collect_power] Done. Rows written: $(wc -l < "$OUT_CSV")"
