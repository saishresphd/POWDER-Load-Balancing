#!/bin/bash
# udp_ramp_latency_all_ues.sh
# For each of the 49 attached UEs on uehost1:
#   1. ICMP ping latency: 20 pings at baseline (idle)
#   2. UDP iperf3 ramp: 1,10,20,50,100,200,300,400,500 Mbps (each 10s)
#      Captures: throughput_actual, jitter_ms, pkt_loss_pct
#   3. ICMP ping latency under load: 20 pings concurrent with 100 Mbps UDP
#
# iperf3 server on core (10.45.0.1) must be running.
# We use a single iperf3 server but UEs run sequentially to avoid port conflict.
#
# Output: /tmp/ran_collect/udp_latency_all_ues.csv

set -uo pipefail
CORE_IP="10.45.0.1"
IPERF_PORT=5201
OUT="/tmp/ran_collect/udp_latency_all_ues.csv"
mkdir -p /tmp/ran_collect

RATES=(1 10 20 50 100 200 300 400 500)
DURATION=10    # seconds per rate step
PING_COUNT=20  # ICMP pings per measurement
PRIME_DUR=3    # seconds to prime scheduler before main test

echo "ue_id,ue_ip,test_type,rate_target_mbps,timestamp,\
throughput_mbps,jitter_ms,pkt_loss_pct,\
ping_min_ms,ping_avg_ms,ping_max_ms,ping_mdev_ms,ping_loss_pct" > "$OUT"

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

run_iperf_udp() {
    local ns="$1" bw="$2" dur="$3"
    sudo ip netns exec "$ns" iperf3 \
        -c "$CORE_IP" -p "$IPERF_PORT" \
        -u -b "${bw}M" -t "$dur" \
        --json 2>/dev/null
}

parse_iperf_udp() {
    local json="$1"
    local tput jitter loss
    # iperf3 JSON: .end.sum.bits_per_second (receiver or sender)
    tput=$(echo "$json" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    # Try receiver sum first, fallback to sender
    s=d.get('end',{}).get('sum',{})
    bps=s.get('bits_per_second',0)
    print(f'{bps/1e6:.3f}')
except: print('NA')
" 2>/dev/null)
    jitter=$(echo "$json" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    s=d.get('end',{}).get('sum',{})
    print(f\"{s.get('jitter_ms',0):.3f}\")
except: print('NA')
" 2>/dev/null)
    loss=$(echo "$json" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    s=d.get('end',{}).get('sum',{})
    lost=s.get('lost_packets',0)
    total=s.get('packets',1)
    print(f'{(lost/max(total,1))*100:.2f}')
except: print('NA')
" 2>/dev/null)
    echo "${tput:-NA},${jitter:-NA},${loss:-NA}"
}

for i in $(seq 1 50); do
    ns="ue${i}"
    # Skip UE40 (known failed attach)
    [ "$i" -eq 40 ] && continue

    # Check if UE has a tun interface
    ue_ip=$(sudo ip netns exec "$ns" ip addr show "tun_srsue${i}" 2>/dev/null \
            | grep -oP 'inet \K[\d.]+' | head -1)
    if [ -z "$ue_ip" ]; then
        log "UE$i: no tun interface, skipping"
        continue
    fi

    log "=== UE$i ($ue_ip) starting ==="
    TS=$(date -Iseconds)

    # ---- 1. Baseline ICMP ping (idle) ----
    log "UE$i: baseline ping ($PING_COUNT packets)"
    ping_out=$(run_ping "$ns" "$PING_COUNT" "0.2")
    ping_stats=$(parse_ping "$ping_out")
    echo "$i,$ue_ip,ping_baseline,0,$TS,NA,NA,NA,$ping_stats" >> "$OUT"

    # ---- 2. UDP ramp ----
    for rate in "${RATES[@]}"; do
        TS=$(date -Iseconds)
        log "UE$i: UDP prime @ ${rate}M (${PRIME_DUR}s)"
        # Prime scheduler so ZMQ allocates PRBs before measurement
        sudo ip netns exec "$ns" iperf3 \
            -c "$CORE_IP" -p "$IPERF_PORT" \
            -u -b "${rate}M" -t "$PRIME_DUR" \
            --json > /dev/null 2>&1 || true
        sleep 0.5

        log "UE$i: UDP ramp @ ${rate}M (${DURATION}s)"
        json_out=$(run_iperf_udp "$ns" "$rate" "$DURATION")
        iperf_stats=$(parse_iperf_udp "$json_out")
        echo "$i,$ue_ip,udp_ramp,$rate,$TS,$iperf_stats,NA,NA,NA,NA" >> "$OUT"
    done

    # ---- 3. Ping under load (concurrent with 100M UDP) ----
    log "UE$i: ping under 100M UDP load"
    TS=$(date -Iseconds)
    # Start iperf3 UDP 100M in background inside netns
    sudo ip netns exec "$ns" iperf3 \
        -c "$CORE_IP" -p "$IPERF_PORT" \
        -u -b "100M" -t 15 \
        --json > /tmp/ran_collect/iperf_bg_ue${i}.json 2>&1 &
    BG_PID=$!
    sleep 2   # let scheduler warm up
    ping_out=$(run_ping "$ns" "$PING_COUNT" "0.3")
    ping_stats=$(parse_ping "$ping_out")
    wait $BG_PID 2>/dev/null || true
    sleep 4   # ensure server fully releases before next UE
    echo "$i,$ue_ip,ping_under_load,100,$TS,NA,NA,NA,$ping_stats" >> "$OUT"

    log "UE$i: done"
    # Gap so iperf3 server resets cleanly
    sleep 6
done

log "=== All UEs done: $OUT ==="
wc -l "$OUT"
