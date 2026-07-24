#!/bin/bash
# measure_power_per_ue_rate_fast.sh
# Resumes from UE19 (UEs 1-18 already done in per_ue_power.csv)
# DURATION=5, no warmup, 1s gap between rates, 1s between UEs
# Appends to existing /tmp/ran_collect/per_ue_power.csv

CORE_IP="10.45.0.1"
IPERF_PORT=5201
DURATION=5
OUT="/tmp/ran_collect/per_ue_power.csv"
RATES="1 10 20 50 100 200 300 400 500"
RESUME_FROM=19    # skip UEs 1..18 already collected

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

# NOTE: no header written — appending to existing CSV

# discover active UEs >= RESUME_FROM
ACTIVE_UES=""
for uid in $(seq 1 50); do
    [ "$uid" -eq 40 ] && continue
    [ "$uid" -lt "$RESUME_FROM" ] && continue
    ns="ue${uid}"
    ip netns list 2>/dev/null | grep -q "^${ns}" || continue
    ip_addr=$(ip netns exec "$ns" ip -4 addr show "tun_srsue${uid}" 2>/dev/null \
         | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
    [ -z "$ip_addr" ] && continue
    ACTIVE_UES="$ACTIVE_UES $uid"
done
ACTIVE_UES=$(echo "$ACTIVE_UES" | tr ' ' '\n' | sort -n | tr '\n' ' ')
log "Resuming from UE${RESUME_FROM}. Remaining UEs: $ACTIVE_UES"

measure_one() {
    local uid=$1 rate=$2
    local ns="ue${uid}"
    local ue_ip
    ue_ip=$(ip netns exec "$ns" ip -4 addr show "tun_srsue${uid}" 2>/dev/null \
            | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
    [ -z "$ue_ip" ] && return

    local TS
    TS=$(date -Iseconds)

    read -r PRE_P0 PRE_P1 PRE_D0 PRE_D1 PRE_T <<< "$(rapl_snap)"

    local result
    result=$(ip netns exec "$ns" iperf3 \
        -c "$CORE_IP" -p "$IPERF_PORT" \
        -u -b "${rate}M" -t "$DURATION" --json 2>/dev/null)

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

    # Sanity check: discard wraparound (negative or > 200W)
    local valid
    valid=$(awk "BEGIN{print ($TOT_W > 10 && $TOT_W < 200) ? 1 : 0}")
    if [ "$valid" -eq 0 ]; then
        log "  UE${uid} ${rate}M: SKIP bad power=${TOT_W}W (counter wrap?)"
        return
    fi

    local TPUT JITTER LOSS
    TPUT=$(echo "$result"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(round(d['end']['sum']['bits_per_second']/1e6,3))" 2>/dev/null || echo "NA")
    JITTER=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(round(d['end']['sum']['jitter_ms'],3))"             2>/dev/null || echo "NA")
    LOSS=$(echo "$result"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(round(d['end']['sum']['lost_percent'],3))"           2>/dev/null || echo "NA")

    log "  UE${uid} ${rate}M: tput=${TPUT}M  cpu=${TOT_W}W  dt=${DELTA_S}s"
    echo "${uid},${ue_ip},${rate},${DURATION},${DELTA_S},${PKG0_W},${PKG1_W},${DRAM0_W},${DRAM1_W},${TOT_W},${TPUT},${JITTER},${LOSS},${TS}" >> "$OUT"
}

for uid in $ACTIVE_UES; do
    log "=== UE${uid} ==="
    for rate in $RATES; do
        measure_one "$uid" "$rate"
        sleep 1
    done
    sleep 1
done

log "DONE. Total rows:"
wc -l "$OUT"
