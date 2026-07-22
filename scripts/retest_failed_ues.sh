#!/bin/bash
# retest_failed_ues.sh
# Retests ONLY the UEs that had 0-throughput due to iperf3 server-busy race.
# Uses fixed sleep gaps to avoid the race. Appends to udp_latency_all_ues.csv.

set +e
CORE_IP="10.45.0.1"
IPERF_PORT=5201
OUT="/tmp/ran_collect/udp_latency_all_ues.csv"
RATES=(1 10 20 50 100 200 300 400 500)
DURATION=10
PRIME_DUR=3
PING_COUNT=20

# UEs to retest (those with mostly 0-throughput rows)
RETEST_UES=(2 3 14 15 17 19 20 22 24 25 28 29 32)

log() { echo "[$(date +%T)] $*"; }

run_ping() {
    local ns="$1" count="$2" interval="$3"
    sudo ip netns exec "$ns" ping -c "$count" -i "$interval" -W 3 "$CORE_IP" 2>/dev/null
}

parse_ping() {
    local output="$1"
    local min avg max mdev loss
    min=$(echo "$output"  | grep -oP 'rtt.*= \K[0-9.]+' | cut -d/ -f1)
    avg=$(echo "$output"  | grep -oP 'rtt.*= [0-9.]+/\K[0-9.]+')
    max=$(echo "$output"  | grep -oP 'rtt.*= [0-9.]+/[0-9.]+/\K[0-9.]+')
    mdev=$(echo "$output" | grep -oP 'rtt.*= [0-9.]+/[0-9.]+/[0-9.]+/\K[0-9.]+')
    loss=$(echo "$output" | grep -oP '[0-9.]+(?=% packet loss)')
    echo "${min:-NA},${avg:-NA},${max:-NA},${mdev:-NA},${loss:-NA}"
}

parse_iperf_udp() {
    local json="$1"
    echo "$json" | python3 -c "
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
except Exception as e:
    print(f'NA,NA,NA')
" 2>/dev/null
}

log "=== Retest of failed UEs: ${RETEST_UES[*]} ==="

for i in "${RETEST_UES[@]}"; do
    ns="ue${i}"
    ue_ip=$(sudo ip netns exec "$ns" ip addr show "tun_srsue${i}" 2>/dev/null \
            | grep -oP 'inet \K[\d.]+' | head -1)
    if [ -z "$ue_ip" ]; then
        log "UE$i: no tun interface, skipping"
        continue
    fi

    log "=== UE$i ($ue_ip) retest ==="

    # Wait for server to be free
    sleep 3

    # Baseline ping
    TS=$(date -Iseconds)
    log "UE$i: baseline ping"
    ping_out=$(run_ping "$ns" "$PING_COUNT" "0.2")
    ping_stats=$(parse_ping "$ping_out")
    echo "$i,$ue_ip,ping_baseline_retest,0,$TS,NA,NA,NA,$ping_stats" >> "$OUT"

    # UDP ramp
    for rate in "${RATES[@]}"; do
        TS=$(date -Iseconds)
        # Prime
        sudo ip netns exec "$ns" iperf3 \
            -c "$CORE_IP" -p "$IPERF_PORT" \
            -u -b "${rate}M" -t "$PRIME_DUR" \
            --json > /dev/null 2>&1 || true
        sleep 1   # extra gap after prime

        log "UE$i: UDP ramp @ ${rate}M"
        json_out=$(sudo ip netns exec "$ns" iperf3 \
            -c "$CORE_IP" -p "$IPERF_PORT" \
            -u -b "${rate}M" -t "$DURATION" \
            --json 2>/dev/null)
        stats=$(parse_iperf_udp "$json_out")
        echo "$i,$ue_ip,udp_ramp_retest,$rate,$TS,$stats,NA,NA,NA,NA" >> "$OUT"
        sleep 2   # server reset between rates
    done

    # Ping under load
    TS=$(date -Iseconds)
    log "UE$i: ping under load"
    sudo ip netns exec "$ns" iperf3 \
        -c "$CORE_IP" -p "$IPERF_PORT" \
        -u -b "100M" -t 20 \
        --json > /tmp/ran_collect/iperf_bg_retest_ue${i}.json 2>&1 &
    BG_PID=$!
    sleep 2
    ping_out=$(run_ping "$ns" "$PING_COUNT" "0.3")
    ping_stats=$(parse_ping "$ping_out")
    wait $BG_PID 2>/dev/null || true
    sleep 5   # full server reset
    echo "$i,$ue_ip,ping_under_load_retest,100,$TS,NA,NA,NA,$ping_stats" >> "$OUT"

    log "UE$i: done. Sleeping 8s..."
    sleep 8
done

log "=== Retest done. Total rows: $(wc -l < $OUT) ==="
