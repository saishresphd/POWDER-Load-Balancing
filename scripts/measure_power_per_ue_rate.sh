#!/bin/bash
# measure_power_per_ue_rate.sh
# ─────────────────────────────────────────────────────────────────────────────
# For each UE x rate: RAPL energy before → iperf3 UDP → RAPL energy after
# Power_W = delta_energy_uj / delta_time_us  (whole-node watts during this UE's test)
# Output: /tmp/ran_collect/per_ue_power.csv
#
# Run: sudo bash measure_power_per_ue_rate.sh
# Namespace naming: ue1..ue49 (not ue1ns)
# Interface:        tun_srsuei (i=uid)
# iperf3 duration:  DURATION seconds (default 8)

set -e
CORE_IP="10.45.0.1"
IPERF_PORT=5201
DURATION=8
OUT="/tmp/ran_collect/per_ue_power.csv"
RATES="1 10 20 50 100 200 300 400 500"

log() { echo "[$(date +%T)] $*"; }

# ── RAPL snapshot: returns "pkg0 pkg1 dram0 dram1 time_us" ───────────────────
rapl_snap() {
    local p0 p1 d0 d1 t
    p0=$(cat /sys/class/powercap/intel-rapl:0/energy_uj 2>/dev/null || echo 0)
    p1=$(cat /sys/class/powercap/intel-rapl:1/energy_uj 2>/dev/null || echo 0)
    d0=$(cat /sys/class/powercap/intel-rapl:0:0/energy_uj 2>/dev/null || echo 0)
    d1=$(cat /sys/class/powercap/intel-rapl:1:0/energy_uj 2>/dev/null || echo 0)
    t=$(date +%s%6N)
    echo "$p0 $p1 $d0 $d1 $t"
}

# ── CSV header ────────────────────────────────────────────────────────────────
echo "ue_id,ue_ip,rate_mbps,duration_s,delta_t_s,\
ue_pkg0_power_W,ue_pkg1_power_W,ue_dram0_power_W,ue_dram1_power_W,ue_total_cpu_W,\
tput_mbps,jitter_ms,loss_pct,timestamp" > "$OUT"

# ── discover active UEs ───────────────────────────────────────────────────────
ACTIVE_UES=""
for uid in $(seq 1 50); do
    [ "$uid" -eq 40 ] && continue
    ns="ue${uid}"
    ip netns list 2>/dev/null | grep -q "^${ns}" || continue
    ip=$(ip netns exec "$ns" ip -4 addr show "tun_srsue${uid}" 2>/dev/null \
         | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
    [ -z "$ip" ] && continue
    ACTIVE_UES="$ACTIVE_UES $uid"
done
ACTIVE_UES=$(echo "$ACTIVE_UES" | tr ' ' '\n' | sort -n | tr '\n' ' ')
N_UES=$(echo "$ACTIVE_UES" | wc -w)
log "Active UEs ($N_UES): $ACTIVE_UES"

measure_one() {
    local uid=$1 rate=$2
    local ns="ue${uid}"
    local ue_ip
    ue_ip=$(ip netns exec "$ns" ip -4 addr show "tun_srsue${uid}" 2>/dev/null \
            | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
    [ -z "$ue_ip" ] && return

    # prime iperf3 server (1s warm-up, discard)
    ip netns exec "$ns" iperf3 -c "$CORE_IP" -p "$IPERF_PORT" \
        -u -b "${rate}M" -t 1 --json >/dev/null 2>&1 || true
    sleep 2

    local TS
    TS=$(date -Iseconds)

    # ── RAPL before ──────────────────────────────────────────────────────────
    read -r PRE_P0 PRE_P1 PRE_D0 PRE_D1 PRE_T <<< "$(rapl_snap)"

    # ── iperf3 measurement ───────────────────────────────────────────────────
    local result
    result=$(ip netns exec "$ns" iperf3 \
        -c "$CORE_IP" -p "$IPERF_PORT" \
        -u -b "${rate}M" -t "$DURATION" --json 2>/dev/null)

    # ── RAPL after ───────────────────────────────────────────────────────────
    read -r POST_P0 POST_P1 POST_D0 POST_D1 POST_T <<< "$(rapl_snap)"

    local DELTA_US=$(( POST_T - PRE_T ))
    [ "$DELTA_US" -le 0 ] && return

    local PKG0_W PKG1_W DRAM0_W DRAM1_W TOT_W DELTA_S
    PKG0_W=$(awk  "BEGIN{printf \"%.3f\",($POST_P0-$PRE_P0)/$DELTA_US}")
    PKG1_W=$(awk  "BEGIN{printf \"%.3f\",($POST_P1-$PRE_P1)/$DELTA_US}")
    DRAM0_W=$(awk "BEGIN{printf \"%.3f\",($POST_D0-$PRE_D0)/$DELTA_US}")
    DRAM1_W=$(awk "BEGIN{printf \"%.3f\",($POST_D1-$PRE_D1)/$DELTA_US}")
    TOT_W=$(awk   "BEGIN{printf \"%.3f\",$PKG0_W+$PKG1_W}")
    DELTA_S=$(awk "BEGIN{printf \"%.2f\",$DELTA_US/1000000}")

    local TPUT JITTER LOSS
    TPUT=$(echo "$result"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(round(d['end']['sum']['bits_per_second']/1e6,3))" 2>/dev/null || echo "NA")
    JITTER=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(round(d['end']['sum']['jitter_ms'],3))"             2>/dev/null || echo "NA")
    LOSS=$(echo "$result"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(round(d['end']['sum']['lost_percent'],3))"           2>/dev/null || echo "NA")

    log "  UE${uid} ${rate}M: tput=${TPUT}M  total_cpu=${TOT_W}W  dt=${DELTA_S}s"
    echo "${uid},${ue_ip},${rate},${DURATION},${DELTA_S},${PKG0_W},${PKG1_W},${DRAM0_W},${DRAM1_W},${TOT_W},${TPUT},${JITTER},${LOSS},${TS}" >> "$OUT"
}

# ── Main loop: one UE at a time, all rates ───────────────────────────────────
for uid in $ACTIVE_UES; do
    log "=== UE${uid} ==="
    for rate in $RATES; do
        measure_one "$uid" "$rate"
        sleep 3
    done
    sleep 2
done

log "DONE. Rows:"
wc -l "$OUT"
