#!/bin/bash
# fill_missing_rates.sh
# Fills ONLY the exact missing rates for each UE — appends to udp_latency_all_ues.csv.
# Runs after retest_failed_ues.sh completes.

set +e
CORE_IP="10.45.0.1"
IPERF_PORT=5201
OUT="/tmp/ran_collect/udp_latency_all_ues.csv"
DURATION=10
PRIME_DUR=3

log() { echo "[$(date +%T)] $*"; }

run_one() {
    local ns="$1" uid="$2" rate="$3" ue_ip="$4"
    local TS=$(date -Iseconds)
    log "UE${uid}: filling rate ${rate}M"

    # Wait for server to be free
    for try in 1 2 3; do
        result=$(sudo ip netns exec "$ns" iperf3 -c "$CORE_IP" -p "$IPERF_PORT" \
            -u -b "${rate}M" -t 1 --json 2>/dev/null)
        err=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error',''))" 2>/dev/null)
        if echo "$err" | grep -q "busy"; then
            log "  server busy, waiting 5s (try $try)..."
            sleep 5
        else
            break
        fi
    done

    # Prime
    sudo ip netns exec "$ns" iperf3 \
        -c "$CORE_IP" -p "$IPERF_PORT" \
        -u -b "${rate}M" -t "$PRIME_DUR" \
        --json > /dev/null 2>&1 || true
    sleep 1

    # Measure
    json_out=$(sudo ip netns exec "$ns" iperf3 \
        -c "$CORE_IP" -p "$IPERF_PORT" \
        -u -b "${rate}M" -t "$DURATION" \
        --json 2>/dev/null)

    stats=$(echo "$json_out" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    s=d.get('end',{}).get('sum',{})
    bps=s.get('bits_per_second',0)
    jit=s.get('jitter_ms',0)
    lost=s.get('lost_packets',0)
    total=s.get('packets',1)
    loss=(lost/max(total,1))*100
    print(f'{bps/1e6:.3f},{jit:.3f},{loss:.2f}')
except: print('NA,NA,NA')
" 2>/dev/null)

    echo "${uid},${ue_ip},udp_ramp_fill,${rate},${TS},${stats},NA,NA,NA,NA" >> "$OUT"
    sleep 3   # server reset
}

# ── Targeted fill table ────────────────────────────────────────────────────
# Format: uid "rate1 rate2 ..."
declare -A MISSING
MISSING[7]="1 10 20 50"
MISSING[10]="500"
MISSING[17]="1 10 20 50 100"
MISSING[19]="1 10 20 50 100 200 300"
MISSING[20]="1 10 20 50 100 200 300"
MISSING[22]="1 10 20 50 100 200 400 500"
MISSING[23]="1 10 20 50"
MISSING[24]="1 10 20 50 100 200 300 400 500"
MISSING[25]="1 10 20 50 100 200 300 400 500"
MISSING[28]="1 10 20 50 100 200 300 400"
MISSING[29]="1 10 20 50 100 200 300 400 500"
MISSING[31]="1"
MISSING[33]="1 10 20 50 100 200 300"
MISSING[38]="1 10 20 50 100 200 300 400 500"
MISSING[43]="1 10 20 50 100 200 300 400 500"
MISSING[44]="20 50 100 200 400 500"
MISSING[45]="1 10 20 50 100"
MISSING[48]="1 10 20 50 100 200 300 400 500"

log "=== fill_missing_rates.sh starting ==="
log "Waiting for retest to finish..."
while pgrep -f retest_failed_ues.sh > /dev/null 2>&1; do
    sleep 10
done
log "Retest done. Starting fill..."

for uid in $(echo "${!MISSING[@]}" | tr ' ' '\n' | sort -n); do
    ns="ue${uid}"
    ue_ip=$(sudo ip netns exec "$ns" ip addr show "tun_srsue${uid}" 2>/dev/null \
            | grep -oP 'inet \K[\d.]+' | head -1)
    if [ -z "$ue_ip" ]; then
        log "UE${uid}: no tun, skipping"
        continue
    fi
    log "=== UE${uid} (${ue_ip}) filling: ${MISSING[$uid]} ==="
    for rate in ${MISSING[$uid]}; do
        run_one "$ns" "$uid" "$rate" "$ue_ip"
    done
done

log "=== fill_missing_rates.sh done. Total rows: $(wc -l < $OUT) ==="
