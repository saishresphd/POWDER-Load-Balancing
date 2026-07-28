#!/bin/bash
# Quick test: run measure_power_per_ue_rate.sh on UE1 only, 2 rates
# to verify the approach works before full 49-UE run

set -e
CORE_IP="10.45.0.1"
IPERF_PORT=5201
DURATION=8
OUT="/tmp/ran_collect/per_ue_power_test.csv"

log() { echo "[$(date +%T)] $*"; }

rapl_snap() {
    local p0 p1 d0 d1 t
    p0=$(cat /sys/class/powercap/intel-rapl:0/energy_uj 2>/dev/null || echo 0)
    p1=$(cat /sys/class/powercap/intel-rapl:1/energy_uj 2>/dev/null || echo 0)
    d0=$(cat /sys/class/powercap/intel-rapl:0:0/energy_uj 2>/dev/null || echo 0)
    d1=$(cat /sys/class/powercap/intel-rapl:1:0/energy_uj 2>/dev/null || echo 0)
    t=$(date +%s%6N)
    echo "$p0 $p1 $d0 $d1 $t"
}

echo "ue_id,ue_ip,rate_mbps,duration_s,delta_t_s,ue_pkg0_power_W,ue_pkg1_power_W,ue_dram0_power_W,ue_dram1_power_W,ue_total_cpu_W,tput_mbps,jitter_ms,loss_pct,timestamp" > "$OUT"

for rate in 1 100 500; do
    uid=1; ns="ue1"
    ue_ip=$(ip netns exec "$ns" ip -4 addr show tun_srsue1 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
    log "Test UE1 rate=${rate}M ip=${ue_ip}"

    # warm-up
    ip netns exec "$ns" iperf3 -c "$CORE_IP" -p "$IPERF_PORT" -u -b "${rate}M" -t 1 --json >/dev/null 2>&1 || true
    sleep 2

    TS=$(date -Iseconds)
    read -r PRE_P0 PRE_P1 PRE_D0 PRE_D1 PRE_T <<< "$(rapl_snap)"

    result=$(ip netns exec "$ns" iperf3 -c "$CORE_IP" -p "$IPERF_PORT" -u -b "${rate}M" -t "$DURATION" --json 2>/dev/null)

    read -r POST_P0 POST_P1 POST_D0 POST_D1 POST_T <<< "$(rapl_snap)"

    DELTA_US=$(( POST_T - PRE_T ))
    PKG0_W=$(awk  "BEGIN{printf \"%.3f\",($POST_P0-$PRE_P0)/$DELTA_US}")
    PKG1_W=$(awk  "BEGIN{printf \"%.3f\",($POST_P1-$PRE_P1)/$DELTA_US}")
    DRAM0_W=$(awk "BEGIN{printf \"%.3f\",($POST_D0-$PRE_D0)/$DELTA_US}")
    DRAM1_W=$(awk "BEGIN{printf \"%.3f\",($POST_D1-$PRE_D1)/$DELTA_US}")
    TOT_W=$(awk   "BEGIN{printf \"%.3f\",$PKG0_W+$PKG1_W}")
    DELTA_S=$(awk "BEGIN{printf \"%.2f\",$DELTA_US/1000000}")

    TPUT=$(echo "$result"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(round(d['end']['sum']['bits_per_second']/1e6,3))" 2>/dev/null || echo "NA")
    JITTER=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(round(d['end']['sum']['jitter_ms'],3))"             2>/dev/null || echo "NA")
    LOSS=$(echo "$result"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(round(d['end']['sum']['lost_percent'],3))"           2>/dev/null || echo "NA")

    log "  rate=${rate}M tput=${TPUT}M pkg0=${PKG0_W}W pkg1=${PKG1_W}W total=${TOT_W}W dt=${DELTA_S}s"
    echo "${uid},${ue_ip},${rate},${DURATION},${DELTA_S},${PKG0_W},${PKG1_W},${DRAM0_W},${DRAM1_W},${TOT_W},${TPUT},${JITTER},${LOSS},${TS}" >> "$OUT"
    sleep 3
done

log "Test done."
cat "$OUT"
