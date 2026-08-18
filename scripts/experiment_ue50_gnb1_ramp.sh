#!/bin/bash
# =============================================================================
# experiment_ue50_gnb1_ramp.sh
#
# PURPOSE:
#   1. Start UE50 on gnb1 (the 50th UE — 49 already connected)
#   2. Ramp iperf3 DL throughput from 1 → 2 → 5 → 10 → 20 → 50 Mbps
#   3. At every throughput step, collect:
#        - gNB1 RAN metrics (SNR/RSRP/RSRQ/MCS/BLER/PDCP/throughput per TTI)
#        - Deep sysmon on gnb1: per-core CPU%, IRQ/s, softIRQ, IPC-proxy,
#          ctxsw, schedstat, RAM, network rx/tx
#        - iperf3 application-layer DL+UL throughput + retransmits + jitter
#        - Latency (ping RTT from UE50 namespace)
#   4. After all ramp steps, stop sysmon + iperf server
#   5. All output goes to /tmp/ran_collect/ue50_gnb1/
#
# Topology reference (MANUAL.md):
#   UE50 port formula (N=50):  gNB TX REP = 40500  (on pc818)
#                               UE  TX REP = 40501  (on pc808)
#   GTP bind addr gnb1 UE50  = 10.10.1.148
#   UE50 IMSI               = 999700000000050
#   UE50 netns              = ue50  (on uehost1 / pc808)
#
# Run from: local machine (or jump host with SSH access to all nodes)
# Usage:  bash scripts/experiment_ue50_gnb1_ramp.sh [USER]
#         USER defaults to "saish"
#
# Prerequisites:
#   • 49 UEs (UE1–49) already attached on gnb1
#   • Open5GS core running on pc811
#   • iperf3 not already bound on core (script manages it)
#   • deep_sysmon.py deployed to /tmp/ on gnb1 (pc818)
#   • enb_ue50.conf deployed to /etc/srsenb/ on gnb1
#   • ue50.conf deployed to /etc/srsue/ on uehost1
# =============================================================================

set -euo pipefail

USER="${1:-saish}"
CORE="saish@pc811.emulab.net"
GNB1="saish@pc818.emulab.net"
UEHOST1="saish@pc808.emulab.net"

UE_N=50
GNB_TX_PORT=40500
UE_TX_PORT=40501
UE_NS="ue50"
PDN_GW="10.45.0.1"
IPERF_PORT=5250      # dedicated iperf3 server port for UE50 experiment
COLLECT_DIR="/tmp/ran_collect/ue50_gnb1"
SYSMON_SCRIPT="/tmp/deep_sysmon.py"

# Throughput ramp steps in Mbps (sustained for STEP_DURATION seconds each)
RAMP_STEPS="1 2 5 10 20 50"
STEP_DURATION=30     # seconds of iperf3 per step
PING_COUNT=20        # pings per step for latency measurement
METRICS_SETTLE=5     # seconds to let metrics CSV stabilise before reading

log() { echo "[$(date +%H:%M:%S)] $*"; }

# ── PHASE 0: Prepare collection directories ──────────────────────────────────
log "=== PHASE 0: Prepare directories ==="

ssh "$GNB1" "mkdir -p $COLLECT_DIR/metrics $COLLECT_DIR/sysmon $COLLECT_DIR/iperf"
ssh "$UEHOST1" "mkdir -p $COLLECT_DIR/iperf $COLLECT_DIR/ping"

# ── PHASE 1: Deploy deep_sysmon.py to gnb1 ───────────────────────────────────
log "=== PHASE 1: Deploy deep_sysmon.py to gnb1 ==="

scp scripts/deep_sysmon.py "${GNB1}:/tmp/deep_sysmon.py"

# ── PHASE 2: Start gnb1 instance for UE50 ────────────────────────────────────
log "=== PHASE 2: Start gnb1 srsenb instance for UE${UE_N} ==="

ssh "$GNB1" "bash -s" << 'GNBEOF'
UE_N=50
GNB_TX_PORT=40500
COLLECT_DIR="/tmp/ran_collect/ue50_gnb1"

# Kill any stale instance for UE50
for PID in $(ps aux | grep "[s]rsenb.*enb_ue${UE_N}.conf" | awk '{print $2}'); do
    sudo kill -9 "$PID" 2>/dev/null || true
done
sleep 2

# Confirm ZMQ port is free
if ss -tnlp | grep -q ":${GNB_TX_PORT} "; then
    echo "ERROR: port ${GNB_TX_PORT} still in use!"
    exit 1
fi

mkdir -p "$COLLECT_DIR"
rm -f "$COLLECT_DIR/gnb1_ue${UE_N}_stdout.log"

# Start srsenb for UE50 — metrics CSV enabled in enb_ue50.conf
sudo bash -c "srsenb /etc/srsenb/enb_ue${UE_N}.conf \
    >> $COLLECT_DIR/gnb1_ue${UE_N}_stdout.log 2>&1 &"

echo "  srsenb UE${UE_N} started, PID=$!"
sleep 12

# Verify ZMQ REP bound
ss -tnlp | grep "${GNB_TX_PORT}" && echo "  ✓ port ${GNB_TX_PORT} LISTEN" \
    || { echo "  ✗ gNB port NOT listening — check $COLLECT_DIR/gnb1_ue${UE_N}_stdout.log"; exit 1; }

# Show MME confirmation
GNBEOF

log "  Checking MME accepted UE${UE_N} gNB slot..."
ssh "$CORE" "grep 'eNB-S1 accepted\|Number of eNBs' /var/log/open5gs/mme.log | tail -5"

# ── PHASE 3: Start srsUE for UE50 on uehost1 ─────────────────────────────────
log "=== PHASE 3: Start srsue UE${UE_N} on uehost1 ==="

ssh "$UEHOST1" "bash -s" << 'UEEOF'
UE_N=50
UE_NS="ue50"
COLLECT_DIR="/tmp/ran_collect/ue50_gnb1"

# Kill stale srsue for UE50
for PID in $(ps aux | grep "[s]rsue.*ue${UE_N}.conf" | awk '{print $2}'); do
    sudo kill -9 "$PID" 2>/dev/null || true
done
sleep 2

# Clear stale tun interface
sudo ip netns exec "$UE_NS" ip link del "tun_srsue${UE_N}" 2>/dev/null || true

# Ensure netns exists
sudo ip netns add "$UE_NS" 2>/dev/null || true

rm -f "$COLLECT_DIR/ue${UE_N}_stdout.log"

sudo bash -c "srsue /etc/srsue/ue${UE_N}.conf \
    >> $COLLECT_DIR/ue${UE_N}_stdout.log 2>&1 &"

echo "  srsue UE${UE_N} started, PID=$!"
UEEOF

log "  Waiting 40s for UE${UE_N} attach..."
sleep 40

# Verify attach
log "  Verifying UE${UE_N} attach..."
UE50_IP=$(ssh "$UEHOST1" "sudo ip netns exec $UE_NS ip -br a show tun_srsue${UE_N} 2>/dev/null | awk '{print \$3}'" || echo "")
if [ -z "$UE50_IP" ]; then
    log "ERROR: UE${UE_N} did not attach! Check $COLLECT_DIR/ue${UE_N}_stdout.log"
    ssh "$UEHOST1" "tail -20 $COLLECT_DIR/ue${UE_N}_stdout.log" || true
    exit 1
fi
log "  ✓ UE${UE_N} attached with IP: $UE50_IP"

# Baseline ping to verify data path
log "  Baseline ping from UE${UE_N} namespace..."
ssh "$UEHOST1" "sudo ip netns exec $UE_NS ping -c 5 -W 3 $PDN_GW" || true

# Verify MME attach log
ssh "$CORE" "grep 'Attach complete.*999700000000050\|Attach complete.*50' /var/log/open5gs/mme.log | tail -3" || true

# ── PHASE 4: Start iperf3 server on core ─────────────────────────────────────
log "=== PHASE 4: Start iperf3 server on core (port $IPERF_PORT) ==="
ssh "$CORE" "pkill -f 'iperf3.*-p $IPERF_PORT' 2>/dev/null || true; sleep 1"
ssh "$CORE" "iperf3 -s -B $PDN_GW -p $IPERF_PORT -D; echo 'iperf3 server started on port $IPERF_PORT'"
sleep 2

# ── PHASE 5: Start deep_sysmon on gnb1 (full experiment duration) ────────────
TOTAL_SYSMON_DURATION=$(( (${#RAMP_STEPS} > 0 ? 6 : 0) * (STEP_DURATION + METRICS_SETTLE + 30) + 120 ))
# Calculate more precisely: 6 steps * ~45s each + overhead
STEP_COUNT=$(echo $RAMP_STEPS | wc -w)
TOTAL_SYSMON_DURATION=$(( STEP_COUNT * (STEP_DURATION + METRICS_SETTLE + 30) + 120 ))

log "=== PHASE 5: Start deep_sysmon on gnb1 (${TOTAL_SYSMON_DURATION}s) ==="
ssh "$GNB1" "nohup python3 /tmp/deep_sysmon.py \
    $TOTAL_SYSMON_DURATION 2 srsenb \
    $COLLECT_DIR/sysmon/deep_gnb1_ue50_ramp.csv \
    > $COLLECT_DIR/sysmon/deep_gnb1_sysmon.log 2>&1 &"
log "  sysmon PID=$(ssh $GNB1 'pgrep -f deep_sysmon.py | head -1')"
sleep 3

# ── PHASE 6: Throughput ramp with per-step collection ────────────────────────
log "=== PHASE 6: Throughput ramp: $RAMP_STEPS Mbps ==="

RAMP_CSV="$COLLECT_DIR/iperf/ue50_ramp_summary.csv"
ssh "$UEHOST1" "echo 'timestamp,ue_id,gnb,step_mbps,dl_actual_mbps,dl_transfer_mb,dl_retransmits,dl_jitter_ms,dl_cpu_sender,dl_cpu_recvr,ul_actual_mbps,ul_transfer_mb,ul_retransmits,ul_cpu_sender,ul_cpu_recvr' > $RAMP_CSV"

STEP_NUM=0
for BW in $RAMP_STEPS; do
    STEP_NUM=$((STEP_NUM + 1))
    BW_BPS=$((BW * 1000000))
    TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    log "--- Step $STEP_NUM: ${BW} Mbps (${STEP_DURATION}s DL + UL) ---"

    # ── 6a: Parallel ping latency during traffic step ──────────────────────
    PING_FILE="$COLLECT_DIR/ping/ue50_gnb1_${BW}mbps_ping.txt"
    ssh "$UEHOST1" "sudo ip netns exec $UE_NS ping -c $PING_COUNT -i 0.5 $PDN_GW \
        > $PING_FILE 2>&1 &"
    PING_PID=$!

    # ── 6b: DL iperf3 (server→UE, reverse mode) ───────────────────────────
    log "  DL iperf3 @ ${BW} Mbps..."
    DL_JSON=$(ssh "$UEHOST1" \
        "sudo ip netns exec $UE_NS iperf3 -c $PDN_GW -p $IPERF_PORT \
            -R -b ${BW_BPS} -t $STEP_DURATION -J 2>/dev/null" || echo '{}')

    DL_STATS=$(echo "$DL_JSON" | python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read())
    e=d['end']
    bps   = e['sum_received']['bits_per_second']
    mb    = e['sum_received']['bytes']/1e6
    rtr   = e['sum_sent'].get('retransmits',0)
    jit   = e['streams'][0].get('receiver',{}).get('jitter_ms', e['streams'][0].get('sender',{}).get('jitter_ms',0))
    cpu_s = e['cpu_utilization_percent']['host_total']
    cpu_r = e['cpu_utilization_percent']['remote_total']
    print(f'{bps/1e6:.4f},{mb:.2f},{rtr},{jit:.4f},{cpu_s:.2f},{cpu_r:.2f}')
except Exception as ex:
    print(f'0,0,0,0,0,0 # parse error: {ex}')
" 2>/dev/null || echo "0,0,0,0,0,0")

    DL_MBPS=$(echo "$DL_STATS" | cut -d, -f1)
    log "  DL actual: ${DL_MBPS} Mbps"

    # ── 6c: Collect gNB1 RAN metrics snapshot immediately after DL ────────
    METRICS_SNAP="$COLLECT_DIR/metrics/gnb1_ue50_step${BW}mbps_$(date +%H%M%S).csv"
    ssh "$GNB1" "
        # Grab last N lines of the metrics CSV (1s period = N rows)
        tail -${STEP_DURATION} /tmp/gnb1_ue50_metrics.csv \
            > $METRICS_SNAP 2>/dev/null || echo 'no metrics csv yet' > $METRICS_SNAP
        echo 'gnb1 metrics snapshot: rows='
        wc -l < $METRICS_SNAP
    "

    # ── 6d: UL iperf3 (UE→server) ─────────────────────────────────────────
    log "  UL iperf3 @ ${BW} Mbps..."
    UL_JSON=$(ssh "$UEHOST1" \
        "sudo ip netns exec $UE_NS iperf3 -c $PDN_GW -p $IPERF_PORT \
            -b ${BW_BPS} -t $STEP_DURATION -J 2>/dev/null" || echo '{}')

    UL_STATS=$(echo "$UL_JSON" | python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read())
    e=d['end']
    bps   = e['sum_sent']['bits_per_second']
    mb    = e['sum_sent']['bytes']/1e6
    rtr   = e['sum_sent'].get('retransmits',0)
    jit   = e['streams'][0].get('sender',{}).get('jitter_ms',0)
    cpu_s = e['cpu_utilization_percent']['host_total']
    cpu_r = e['cpu_utilization_percent']['remote_total']
    print(f'{bps/1e6:.4f},{mb:.2f},{rtr},{jit:.4f},{cpu_s:.2f},{cpu_r:.2f}')
except Exception as ex:
    print(f'0,0,0,0,0,0 # parse error: {ex}')
" 2>/dev/null || echo "0,0,0,0,0,0")

    UL_MBPS=$(echo "$UL_STATS" | cut -d, -f1)
    log "  UL actual: ${UL_MBPS} Mbps"

    # ── 6e: Wait for ping to complete ─────────────────────────────────────
    wait $PING_PID 2>/dev/null || true
    PING_SUMMARY=$(ssh "$UEHOST1" "
        grep -E 'rtt|packet loss' $PING_FILE 2>/dev/null | tr '\n' '|' || echo 'ping unavail'
    ")
    log "  Ping summary: $PING_SUMMARY"

    # ── 6f: Write step summary row ─────────────────────────────────────────
    ssh "$UEHOST1" "echo '$TS,50,gnb1,$BW,$DL_STATS,$UL_STATS' >> $RAMP_CSV"

    # ── 6g: Snapshot UE50 srslog metrics (SNR/RSRP/MCS lines) ────────────
    UE_LOG_SNAP="$COLLECT_DIR/iperf/ue50_ue_log_step${BW}mbps.txt"
    ssh "$UEHOST1" "
        grep -E 'SNR|RSRP|RSRQ|MCS|BLER|PDCP|dl_brate|ul_brate|RRC|attach' \
            /tmp/ue_logs/ue50_stdout.log 2>/dev/null | tail -50 \
            > $UE_LOG_SNAP || echo 'no ue log yet' > $UE_LOG_SNAP
    "

    # ── 6h: Snapshot gNB1 stdout log lines for UE50 ───────────────────────
    GNB_LOG_SNAP="$COLLECT_DIR/iperf/gnb1_ue50_log_step${BW}mbps.txt"
    ssh "$GNB1" "
        tail -100 $COLLECT_DIR/gnb1_ue${UE_N}_stdout.log 2>/dev/null \
            > $GNB_LOG_SNAP || echo 'no gnb log yet' > $GNB_LOG_SNAP
    "

    log "  Step $STEP_NUM/${STEP_COUNT} complete. Settling ${METRICS_SETTLE}s..."
    sleep $METRICS_SETTLE
done

# ── PHASE 7: Collect full gNB1 metrics CSV for UE50 ─────────────────────────
log "=== PHASE 7: Copy full gNB1 metrics CSV for UE50 ==="
ssh "$GNB1" "
    cp /tmp/gnb1_ue50_metrics.csv $COLLECT_DIR/metrics/gnb1_ue50_metrics_full.csv 2>/dev/null \
        && wc -l $COLLECT_DIR/metrics/gnb1_ue50_metrics_full.csv \
        || echo 'metrics CSV not found'
"

# ── PHASE 8: Stop iperf3 server on core ──────────────────────────────────────
log "=== PHASE 8: Stop iperf3 server ==="
ssh "$CORE" "pkill -f 'iperf3.*-p $IPERF_PORT' 2>/dev/null || true"

# ── PHASE 9: Wait for sysmon to finish, then snapshot final state ─────────────
log "=== PHASE 9: Sysmon still running (will finish naturally). Final state snapshot ==="

# Snapshot current system state on gnb1
ssh "$GNB1" "bash -s" << 'SNAPEOF'
COLLECT_DIR="/tmp/ran_collect/ue50_gnb1"
TS=$(date +%Y%m%d_%H%M%S)

echo "=== CPU state (per-core) ===" > "$COLLECT_DIR/gnb1_final_snapshot_${TS}.txt"
mpstat -P ALL 1 3 2>/dev/null >> "$COLLECT_DIR/gnb1_final_snapshot_${TS}.txt" || true

echo "" >> "$COLLECT_DIR/gnb1_final_snapshot_${TS}.txt"
echo "=== IRQ counts ===" >> "$COLLECT_DIR/gnb1_final_snapshot_${TS}.txt"
cat /proc/interrupts >> "$COLLECT_DIR/gnb1_final_snapshot_${TS}.txt" 2>/dev/null || true

echo "" >> "$COLLECT_DIR/gnb1_final_snapshot_${TS}.txt"
echo "=== CPU frequency ===" >> "$COLLECT_DIR/gnb1_final_snapshot_${TS}.txt"
for cpu_dir in /sys/devices/system/cpu/cpu*/cpufreq/; do
    cpu=$(basename "$(dirname "$cpu_dir")")
    freq=$(cat "${cpu_dir}scaling_cur_freq" 2>/dev/null || echo "NA")
    governor=$(cat "${cpu_dir}scaling_governor" 2>/dev/null || echo "NA")
    echo "  $cpu: ${freq} Hz  governor=${governor}"
done >> "$COLLECT_DIR/gnb1_final_snapshot_${TS}.txt"

echo "" >> "$COLLECT_DIR/gnb1_final_snapshot_${TS}.txt"
echo "=== CPU power (Intel RAPL if available) ===" >> "$COLLECT_DIR/gnb1_final_snapshot_${TS}.txt"
for energy_file in /sys/class/powercap/intel-rapl:*/energy_uj; do
    domain=$(echo "$energy_file" | grep -oP 'intel-rapl:[^/]+')
    name=$(cat "$(dirname $energy_file)/name" 2>/dev/null || echo "$domain")
    uj=$(cat "$energy_file" 2>/dev/null || echo "NA")
    echo "  $name: ${uj} uJ"
done >> "$COLLECT_DIR/gnb1_final_snapshot_${TS}.txt" 2>/dev/null || true

echo "" >> "$COLLECT_DIR/gnb1_final_snapshot_${TS}.txt"
echo "=== Memory info ===" >> "$COLLECT_DIR/gnb1_final_snapshot_${TS}.txt"
free -m >> "$COLLECT_DIR/gnb1_final_snapshot_${TS}.txt"

echo "" >> "$COLLECT_DIR/gnb1_final_snapshot_${TS}.txt"
echo "=== Load average ===" >> "$COLLECT_DIR/gnb1_final_snapshot_${TS}.txt"
uptime >> "$COLLECT_DIR/gnb1_final_snapshot_${TS}.txt"

echo "" >> "$COLLECT_DIR/gnb1_final_snapshot_${TS}.txt"
echo "=== srsenb process stats (UE50) ===" >> "$COLLECT_DIR/gnb1_final_snapshot_${TS}.txt"
ps aux | grep '[s]rsenb.*ue50' >> "$COLLECT_DIR/gnb1_final_snapshot_${TS}.txt" || true

echo "Snapshot written: gnb1_final_snapshot_${TS}.txt"
SNAPEOF

# ── PHASE 10: Print summary ───────────────────────────────────────────────────
log "=== PHASE 10: Summary ==="
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║     UE50 on gNB1 — Ramp Experiment Complete          ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  UE50 IP   : $UE50_IP"
echo "║  Ramp steps: $RAMP_STEPS Mbps"
echo "║  Data dir  : gnb1:$COLLECT_DIR"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Next step : run scripts/loadbalance_ue50_to_gnb2.sh ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
log "Ramp experiment complete. UE50 remains attached on gnb1."
log "Run scripts/loadbalance_ue50_to_gnb2.sh to perform handover."
