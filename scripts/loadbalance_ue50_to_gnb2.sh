#!/bin/bash
# =============================================================================
# loadbalance_ue50_to_gnb2.sh
#
# PURPOSE:
#   Load-balance UE50 from gnb1 → gnb2, collecting comprehensive transition data:
#
#   PRE-HANDOVER (while still on gnb1 @ max throughput):
#     - gNB1 metrics: SNR, RSRP, RSRQ, MCS, BLER, PDCP, dl/ul brate
#     - CPU: per-core %, IRQ/s, softIRQ, IPC-proxy, ctxsw, freq, power (RAPL)
#     - Latency: ping RTT from UE50 namespace
#     - Network: rx/tx bytes/s on gnb1
#
#   TRANSITION (handover execution with timestamps):
#     - T0: capture pre-handover final state
#     - T1: stop UE50 srsue on uehost1
#     - T2: stop gnb1 srsenb slot for UE50
#     - T3: start gnb2 srsenb slot for UE50
#     - T4: start UE50 srsue pointing at gnb2
#     - T5: UE50 attach complete on gnb2
#     - T6: first successful ping from gnb2
#     - Δ timing: T1-T0, T3-T2, T5-T4, T6-T4 (handover latency)
#
#   POST-HANDOVER (on gnb2 @ max throughput):
#     - gNB2 metrics: all same RF/MAC metrics
#     - CPU on gnb2: same deep sysmon metrics
#     - iperf3 DL @ max (50 Mbps target) sustained 60s
#     - Latency: ping RTT from UE50 namespace on gnb2
#
# Architecture (from MANUAL.md):
#   UE50 on gnb1: gNB TX=40500 (pc818), UE TX=40501 (pc808)
#   UE50 on gnb2: we use LB slot — gNB TX=60500 (pc802), UE TX=60501 (pc801)
#     gtp_bind_addr on gnb2 for this slot: 10.10.1.250  (alias to be added)
#
# Run from: local machine / jump host
# Usage:   bash scripts/loadbalance_ue50_to_gnb2.sh [USER]
#
# Prerequisites:
#   - experiment_ue50_gnb1_ramp.sh completed (UE50 attached on gnb1)
#   - deep_sysmon.py on both pc818 and pc802
# =============================================================================

set -euo pipefail

USER_ARG="${1:-saish}"
CORE="saish@pc811.emulab.net"
GNB1="saish@pc818.emulab.net"
GNB2="saish@pc802.emulab.net"
UEHOST1="saish@pc808.emulab.net"   # UE50 was here (gnb1 phase)

UE_N=50
GNB1_TX_PORT=40500
GNB1_UE_TX_PORT=40501
GNB1_GTP_ADDR="10.10.1.148"
GNB1_IP="10.10.1.2"

# gnb2 slot for UE50 — LB target port space (6JJJ0 scheme from MANUAL)
# j=50 → gNB TX = 60500, UE TX = 60501; gtp_bind = 10.10.1.250
GNB2_TX_PORT=60500
GNB2_UE_TX_PORT=60501
GNB2_GTP_ADDR="10.10.1.250"
GNB2_IP="10.10.1.3"

UE_NS="ue50"
PDN_GW="10.45.0.1"
IPERF_PORT=5250
MAX_BW_MBPS=50
MAX_BW_BPS=$((MAX_BW_MBPS * 1000000))
COLLECT_DIR_GNB1="/tmp/ran_collect/ue50_gnb1"
COLLECT_DIR_LB="/tmp/ran_collect/ue50_lb_transition"
COLLECT_DIR_GNB2="/tmp/ran_collect/ue50_gnb2"
SYSMON_POST_DURATION=120   # seconds of sysmon to collect on gnb2 post-handover
PING_COUNT=30
STEP_DURATION=60   # iperf duration on gnb2 post-handover

log()  { echo "[$(date +%H:%M:%SZ)] $*"; }
tsnow() { date +%s%N | awk '{printf "%.6f\n", $1/1e9}'; }

# ── PHASE 0: Setup directories ────────────────────────────────────────────────
log "=== PHASE 0: Prepare directories ==="
ssh "$GNB1"   "mkdir -p $COLLECT_DIR_GNB1/sysmon $COLLECT_DIR_LB"
ssh "$GNB2"   "mkdir -p $COLLECT_DIR_GNB2/metrics $COLLECT_DIR_GNB2/sysmon $COLLECT_DIR_LB"
ssh "$UEHOST1" "mkdir -p $COLLECT_DIR_LB $COLLECT_DIR_GNB2/iperf $COLLECT_DIR_GNB2/ping"

# ── PHASE 1: Pre-handover snapshot on gnb1 @ max throughput ──────────────────
log "=== PHASE 1: Pre-handover baseline — gnb1 @ ${MAX_BW_MBPS} Mbps ==="

# Start iperf3 server
ssh "$CORE" "pkill -f 'iperf3.*-p $IPERF_PORT' 2>/dev/null || true; sleep 1"
ssh "$CORE" "iperf3 -s -B $PDN_GW -p $IPERF_PORT -D"
sleep 2

# Start deep_sysmon on gnb1 for pre-handover window
log "  Starting pre-handover sysmon on gnb1 (60s)..."
ssh "$GNB1" "nohup python3 /tmp/deep_sysmon.py \
    60 2 srsenb \
    $COLLECT_DIR_LB/pre_handover_gnb1_sysmon.csv \
    > $COLLECT_DIR_LB/pre_handover_gnb1_sysmon.log 2>&1 &"

# Drive max throughput DL for pre-HO baseline (30s)
log "  Pre-HO DL iperf3 @ $MAX_BW_MBPS Mbps on gnb1..."
PRE_HO_DL_JSON=$(ssh "$UEHOST1" \
    "sudo ip netns exec $UE_NS iperf3 -c $PDN_GW -p $IPERF_PORT \
        -R -b ${MAX_BW_BPS} -t 30 -J 2>/dev/null" || echo '{}')
PRE_HO_DL=$(echo "$PRE_HO_DL_JSON" | python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read())
    e=d['end']
    bps=e['sum_received']['bits_per_second']
    mb=e['sum_received']['bytes']/1e6
    rtr=e['sum_sent'].get('retransmits',0)
    cpu_s=e['cpu_utilization_percent']['host_total']
    cpu_r=e['cpu_utilization_percent']['remote_total']
    print(f'dl_mbps={bps/1e6:.3f} mb={mb:.1f} rtr={rtr} cpu_s={cpu_s:.1f} cpu_r={cpu_r:.1f}')
except: print('pre-HO DL parse error')
" 2>/dev/null || echo "pre-HO DL failed")
log "  Pre-HO DL: $PRE_HO_DL"

# Pre-HO latency
log "  Pre-HO latency (ping UE50 → $PDN_GW)..."
ssh "$UEHOST1" "sudo ip netns exec $UE_NS ping -c $PING_COUNT -i 0.2 $PDN_GW \
    > $COLLECT_DIR_LB/pre_ho_ping_gnb1.txt 2>&1; \
    grep -E 'rtt|packet loss' $COLLECT_DIR_LB/pre_ho_ping_gnb1.txt || true"

# Pre-HO gNB1 metrics snapshot
log "  Snapshotting gNB1 UE50 metrics CSV (last 30 rows)..."
ssh "$GNB1" "tail -30 /tmp/gnb1_ue50_metrics.csv \
    > $COLLECT_DIR_LB/pre_ho_gnb1_ue50_metrics_tail.csv 2>/dev/null || true"

# Pre-HO CPU/IRQ/freq/power snapshot on gnb1
log "  Pre-HO CPU/IRQ/power snapshot on gnb1..."
ssh "$GNB1" "bash -s" << 'PRESNAP'
COLLECT_DIR_LB="/tmp/ran_collect/ue50_lb_transition"
TS=$(date +%H%M%S)

{
echo "=== [PRE-HANDOVER] gnb1 CPU per-core ==="
cat /proc/stat | grep "^cpu[0-9]" | awk '{used=$2+$3+$4+$6+$7+$8; total=used+$5; printf "  %s: busy=%.1f%%\n", $1, (total>0 ? 100*used/total : 0)}' 2>/dev/null || true

echo ""
echo "=== [PRE-HANDOVER] CPU frequencies ==="
for cpu_dir in /sys/devices/system/cpu/cpu*/cpufreq/; do
    cpu=$(basename "$(dirname "$cpu_dir")")
    freq_cur=$(cat "${cpu_dir}scaling_cur_freq" 2>/dev/null || echo "NA")
    freq_max=$(cat "${cpu_dir}cpuinfo_max_freq" 2>/dev/null || echo "NA")
    gov=$(cat "${cpu_dir}scaling_governor" 2>/dev/null || echo "NA")
    echo "  $cpu: cur=${freq_cur}Hz max=${freq_max}Hz gov=${gov}"
done

echo ""
echo "=== [PRE-HANDOVER] RAPL CPU power ==="
for domain_dir in /sys/class/powercap/intel-rapl:*/; do
    name=$(cat "${domain_dir}name" 2>/dev/null || echo "$(basename $domain_dir)")
    uj1=$(cat "${domain_dir}energy_uj" 2>/dev/null || echo "NA")
    sleep 1
    uj2=$(cat "${domain_dir}energy_uj" 2>/dev/null || echo "NA")
    if [[ "$uj1" =~ ^[0-9]+$ ]] && [[ "$uj2" =~ ^[0-9]+$ ]]; then
        watts=$(awk "BEGIN{printf \"%.2f\", ($uj2-$uj1)/1e6}")
        echo "  $name: ${watts}W  (energy_uj=$uj2)"
    else
        echo "  $name: energy_uj=$uj1 (RAPL not readable)"
    fi
done 2>/dev/null || echo "  RAPL not available"

echo ""
echo "=== [PRE-HANDOVER] IRQ top-10 ==="
sort -t: -k2 -n -r /proc/interrupts 2>/dev/null | head -10 || true

echo ""
echo "=== [PRE-HANDOVER] Softirq rates ==="
cat /proc/softirqs | head -20 || true

echo ""
echo "=== [PRE-HANDOVER] srsenb UE50 process ==="
ps aux | grep '[s]rsenb.*ue50' || true

echo ""
echo "=== [PRE-HANDOVER] Load average ==="
uptime || true

} > "$COLLECT_DIR_LB/pre_ho_gnb1_system_snapshot.txt"
echo "Pre-HO snapshot written."
PRESNAP

# ── PHASE 2: Record T0 timestamp ─────────────────────────────────────────────
T0=$(tsnow)
log "=== PHASE 2: HANDOVER STARTS — T0=$T0 ==="
echo "T0_handover_start: $T0" > "$COLLECT_DIR_LB/handover_timing.txt"

# ── PHASE 3: Stop iperf3, prepare gnb2 slot for UE50 ─────────────────────────
log "=== PHASE 3: Stop iperf, prepare gnb2 slot ==="
ssh "$CORE" "pkill -f 'iperf3.*-p $IPERF_PORT' 2>/dev/null || true"

# Add IP alias 10.10.1.250 on gnb2 for UE50 gtp_bind_addr
ssh "$GNB2" "
    sudo ip addr add ${GNB2_GTP_ADDR}/24 dev enp6s0f3 2>/dev/null \
        && echo 'Added alias ${GNB2_GTP_ADDR} on gnb2' \
        || echo 'Alias ${GNB2_GTP_ADDR} already exists on gnb2'
"

# Write gnb2 config for UE50 slot
log "  Writing enb_ue50.conf on gnb2 (port $GNB2_TX_PORT)..."
ssh "$GNB2" "bash -s" << GNBCFG
sudo tee /etc/srsenb/enb_ue50_lb.conf > /dev/null << 'CONF'
[enb]
enb_id = 0x132
mcc = 999
mnc = 70
mme_addr = 10.10.1.1
gtp_bind_addr = ${GNB2_GTP_ADDR}
s1c_bind_addr = ${GNB2_GTP_ADDR}
s1c_bind_port = 0
n_prb = 50
[enb_files]
sib_config  = /etc/srsenb/sib.conf
rr_config   = /etc/srsenb/rr.conf
rb_config   = /etc/srsenb/rb.conf
[rf]
dl_earfcn = 3350
tx_gain   = 80
rx_gain   = 40
device_name = zmq
device_args = fail_on_disconnect=true,tx_port=tcp://*:${GNB2_TX_PORT},rx_port=tcp://10.10.1.4:${GNB2_UE_TX_PORT},id=enb50_lb,base_srate=11.52e6
[expert]
rrc_inactivity_timer   = 1073741823
metrics_csv_enable     = true
metrics_csv_filename   = /tmp/gnb2_ue50_metrics.csv
metrics_period_secs    = 1
[log]
all_level = info
filename  = /tmp/gnb2_logs/ue50.log
file_max_size = -1
[pcap]
enable = false
CONF
echo "gnb2 UE50 LB config written"
GNBCFG

# Write UE50 config targeting gnb2
log "  Writing ue50_gnb2.conf on uehost1..."
ssh "$UEHOST1" "bash -s" << UECFG
IMSI=$(printf "99970%010d" 50)
sudo tee /etc/srsue/ue50_gnb2.conf > /dev/null << 'CONF'
[rf]
freq_offset   = 0
tx_gain       = 80
rx_gain       = 40
srate         = 11.52e6
nof_antennas  = 1
device_name   = zmq
device_args   = tx_port=tcp://*:${GNB2_UE_TX_PORT},rx_port=tcp://${GNB2_IP}:${GNB2_TX_PORT},id=ue50_gnb2,base_srate=11.52e6
[rat.eutra]
dl_earfcn    = 3350
nof_carriers = 1
[usim]
mode = soft
algo = milenage
opc  = 63BFA50EE6523365FF14C1F45F88737D
k    = 00112233445566778899AABBCCDDEEFF
imsi = 999700000000050
imei = 353490060000050
[rrc]
release     = 8
ue_category = 4
[nas]
apn          = internet
apn_protocol = ipv4
[gw]
netns      = ue50
ip_devname = tun_srsue50
ip_netmask = 255.255.255.0
[log]
all_level = info
filename  = /tmp/ue_logs/ue50_gnb2_stdout.log
[pcap]
enable = none
CONF
echo "ue50_gnb2.conf written"
UECFG

# ── PHASE 4: T1 — Stop UE50 on uehost1 ───────────────────────────────────────
T1=$(tsnow)
log "=== PHASE 4: T1=$T1 — Stop UE50 srsue on uehost1 ==="
echo "T1_ue_stop: $T1" >> "$COLLECT_DIR_LB/handover_timing.txt"

ssh "$UEHOST1" "
    for PID in \$(ps aux | grep '[s]rsue.*ue50' | awk '{print \$2}'); do
        sudo kill -9 \$PID 2>/dev/null || true
    done
    echo 'UE50 srsue killed'
"
sleep 2

# ── PHASE 5: T2 — Stop gnb1 srsenb slot for UE50 ─────────────────────────────
T2=$(tsnow)
log "=== PHASE 5: T2=$T2 — Stop gnb1 srsenb UE50 ==="
echo "T2_gnb1_slot_stop: $T2" >> "$COLLECT_DIR_LB/handover_timing.txt"

ssh "$GNB1" "
    for PID in \$(ps aux | grep '[s]rsenb.*enb_ue50' | awk '{print \$2}'); do
        sudo kill -9 \$PID 2>/dev/null || true
    done
    sleep 3
    ss -tnlp | grep ':40500 ' && echo 'WARN: port 40500 still bound!' || echo 'port 40500 free'
"

# Snapshot MME state after gnb1 slot removal
ssh "$CORE" "grep 'eNB-S1\|Number of eNBs' /var/log/open5gs/mme.log | tail -6" 2>/dev/null || true

# ── PHASE 6: T3 — Start gnb2 slot for UE50 ───────────────────────────────────
T3=$(tsnow)
log "=== PHASE 6: T3=$T3 — Start gnb2 srsenb for UE50 ==="
echo "T3_gnb2_slot_start: $T3" >> "$COLLECT_DIR_LB/handover_timing.txt"

ssh "$GNB2" "
    mkdir -p /tmp/gnb2_logs $COLLECT_DIR_GNB2/metrics
    rm -f /tmp/gnb2_logs/ue50_stdout.log
    sudo bash -c 'srsenb /etc/srsenb/enb_ue50_lb.conf \
        >> /tmp/gnb2_logs/ue50_stdout.log 2>&1 &'
    echo 'gnb2 UE50 srsenb started PID=\$!'
"

log "  Waiting 12s for gnb2 ZMQ REP to bind..."
sleep 12

# Verify gnb2 slot is ready
GNB2_LISTEN=$(ssh "$GNB2" "ss -tnlp | grep ':${GNB2_TX_PORT} '" || true)
if [ -z "$GNB2_LISTEN" ]; then
    log "  ERROR: gnb2 port $GNB2_TX_PORT not listening!"
    ssh "$GNB2" "tail -20 /tmp/gnb2_logs/ue50_stdout.log" || true
    echo "T3_gnb2_bind_FAILED" >> "$COLLECT_DIR_LB/handover_timing.txt"
    exit 1
fi
T3_BIND=$(tsnow)
log "  ✓ gnb2 port $GNB2_TX_PORT listening at T3_bind=$T3_BIND"
echo "T3_gnb2_port_bound: $T3_BIND" >> "$COLLECT_DIR_LB/handover_timing.txt"

# Verify MME accepted gnb2 S1 connection
ssh "$CORE" "grep 'eNB-S1 accepted\[${GNB2_GTP_ADDR}\]\|Number of eNBs' \
    /var/log/open5gs/mme.log | tail -6" 2>/dev/null || true

# ── PHASE 7: Start deep_sysmon on gnb2 (covers transition + post-HO) ─────────
log "=== PHASE 7: Start deep_sysmon on gnb2 (${SYSMON_POST_DURATION}s) ==="
scp scripts/deep_sysmon.py "${GNB2}:/tmp/deep_sysmon.py"
ssh "$GNB2" "nohup python3 /tmp/deep_sysmon.py \
    $SYSMON_POST_DURATION 2 srsenb \
    $COLLECT_DIR_GNB2/sysmon/deep_gnb2_ue50.csv \
    > $COLLECT_DIR_GNB2/sysmon/deep_gnb2_sysmon.log 2>&1 &"
log "  gnb2 sysmon started, PID=$(ssh $GNB2 'pgrep -f deep_sysmon.py | head -1')"

# ── PHASE 8: T4 — Start UE50 srsue pointing at gnb2 ─────────────────────────
T4=$(tsnow)
log "=== PHASE 8: T4=$T4 — Start UE50 srsue → gnb2 ==="
echo "T4_ue_gnb2_start: $T4" >> "$COLLECT_DIR_LB/handover_timing.txt"

ssh "$UEHOST1" "
    # Clear stale tun interface
    sudo ip netns exec $UE_NS ip link del tun_srsue${UE_N} 2>/dev/null || true
    rm -f /tmp/ue_logs/ue50_gnb2_stdout.log
    sudo bash -c 'srsue /etc/srsue/ue50_gnb2.conf \
        >> /tmp/ue_logs/ue50_gnb2_stdout.log 2>&1 &'
    echo 'UE50 srsue → gnb2 started PID=\$!'
"

# ── PHASE 9: Wait for UE50 attach on gnb2 (poll) ─────────────────────────────
log "=== PHASE 9: Polling for UE50 attach on gnb2 ==="
ATTACH_TIMEOUT=60
POLL_START=$(date +%s)
UE50_GNB2_IP=""

while true; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - POLL_START))
    UE50_GNB2_IP=$(ssh "$UEHOST1" \
        "sudo ip netns exec $UE_NS ip -br a show tun_srsue${UE_N} 2>/dev/null \
         | awk '{print \$3}'" 2>/dev/null || echo "")
    if [ -n "$UE50_GNB2_IP" ]; then
        break
    fi
    if [ "$ELAPSED" -ge "$ATTACH_TIMEOUT" ]; then
        log "  TIMEOUT: UE50 did not attach on gnb2 within ${ATTACH_TIMEOUT}s"
        ssh "$UEHOST1" "tail -20 /tmp/ue_logs/ue50_gnb2_stdout.log" || true
        echo "T5_attach_TIMEOUT" >> "$COLLECT_DIR_LB/handover_timing.txt"
        break
    fi
    log "  [${ELAPSED}s] Waiting for UE50 tun interface in $UE_NS..."
    sleep 3
done

T5=$(tsnow)
log "  T5=$T5 — UE50 attached on gnb2, IP=$UE50_GNB2_IP"
echo "T5_ue_attached_gnb2: $T5" >> "$COLLECT_DIR_LB/handover_timing.txt"
echo "UE50_gnb2_ip: $UE50_GNB2_IP" >> "$COLLECT_DIR_LB/handover_timing.txt"

# ── PHASE 10: T6 — First ping from gnb2 ──────────────────────────────────────
log "=== PHASE 10: T6 — First ping from UE50 on gnb2 ==="
FIRST_PING=$(ssh "$UEHOST1" \
    "sudo ip netns exec $UE_NS ping -c 3 -W 3 $PDN_GW 2>&1" || echo "ping failed")
T6=$(tsnow)
echo "T6_first_ping: $T6" >> "$COLLECT_DIR_LB/handover_timing.txt"
echo "T6_ping_result: $FIRST_PING" >> "$COLLECT_DIR_LB/handover_timing.txt"
log "  T6=$T6 — First ping: $(echo "$FIRST_PING" | grep -oE '[0-9]+ received|ping failed' | head -1)"

# ── Print handover timing summary ─────────────────────────────────────────────
log "--- Handover timing summary ---"
python3 - << TIMING
T0 = $T0
T1 = $T1
T2 = $T2
T3 = $T3
T3b= $T3_BIND
T4 = $T4
T5 = $T5
T6 = $T6
print(f"  T0  handover_start       : {T0:.3f}s")
print(f"  T1  ue_stop (gnb1)       : {T1:.3f}s  Δ={(T1-T0)*1000:.0f}ms")
print(f"  T2  gnb1_slot_stop       : {T2:.3f}s  Δ={(T2-T0)*1000:.0f}ms")
print(f"  T3  gnb2_slot_start      : {T3:.3f}s  Δ={(T3-T0)*1000:.0f}ms")
print(f"  T3b gnb2_port_bound      : {T3b:.3f}s Δ={(T3b-T0)*1000:.0f}ms")
print(f"  T4  ue_gnb2_restart      : {T4:.3f}s  Δ={(T4-T0)*1000:.0f}ms")
print(f"  T5  ue_attached_gnb2     : {T5:.3f}s  Δ={(T5-T0)*1000:.0f}ms")
print(f"  T6  first_ping           : {T6:.3f}s  Δ={(T6-T0)*1000:.0f}ms")
print(f"")
print(f"  Total handover latency   : {(T5-T0)*1000:.0f}ms  (T0→T5)")
print(f"  First-packet latency     : {(T6-T0)*1000:.0f}ms  (T0→T6)")
print(f"  gNB1 teardown time       : {(T2-T1)*1000:.0f}ms")
print(f"  gNB2 bind time           : {(T3b-T3)*1000:.0f}ms")
print(f"  UE re-attach time        : {(T5-T4)*1000:.0f}ms")
TIMING

# ── PHASE 11: Post-handover — gnb2 @ max throughput with full data collection──
log "=== PHASE 11: Post-HO — gnb2 @ ${MAX_BW_MBPS} Mbps (${STEP_DURATION}s) ==="

# Start iperf3 server
ssh "$CORE" "pkill -f 'iperf3.*-p $IPERF_PORT' 2>/dev/null || true; sleep 1"
ssh "$CORE" "iperf3 -s -B $PDN_GW -p $IPERF_PORT -D"
sleep 2

# Parallel ping for latency during max throughput
log "  Latency during max throughput on gnb2..."
ssh "$UEHOST1" "sudo ip netns exec $UE_NS ping -c $PING_COUNT -i 0.5 $PDN_GW \
    > $COLLECT_DIR_GNB2/ping/ue50_gnb2_max_ping.txt 2>&1 &"
PING_PID=$!

# DL iperf3 @ max on gnb2
log "  DL iperf3 @ $MAX_BW_MBPS Mbps on gnb2..."
POST_HO_DL_JSON=$(ssh "$UEHOST1" \
    "sudo ip netns exec $UE_NS iperf3 -c $PDN_GW -p $IPERF_PORT \
        -R -b ${MAX_BW_BPS} -t $STEP_DURATION -J 2>/dev/null" || echo '{}')
POST_HO_DL=$(echo "$POST_HO_DL_JSON" | python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read())
    e=d['end']
    bps=e['sum_received']['bits_per_second']
    mb=e['sum_received']['bytes']/1e6
    rtr=e['sum_sent'].get('retransmits',0)
    cpu_s=e['cpu_utilization_percent']['host_total']
    cpu_r=e['cpu_utilization_percent']['remote_total']
    print(f'dl_mbps={bps/1e6:.3f} mb={mb:.1f} rtr={rtr} cpu_s={cpu_s:.1f} cpu_r={cpu_r:.1f}')
except: print('parse error')
" 2>/dev/null || echo "post-HO DL failed")
log "  Post-HO DL (gnb2): $POST_HO_DL"

wait $PING_PID 2>/dev/null || true
POST_HO_PING=$(ssh "$UEHOST1" \
    "grep -E 'rtt|packet loss' $COLLECT_DIR_GNB2/ping/ue50_gnb2_max_ping.txt | tr '\n' '|'" || echo "ping unavail")
log "  Post-HO ping: $POST_HO_PING"

# UL iperf3 @ max on gnb2
log "  UL iperf3 @ $MAX_BW_MBPS Mbps on gnb2..."
POST_HO_UL_JSON=$(ssh "$UEHOST1" \
    "sudo ip netns exec $UE_NS iperf3 -c $PDN_GW -p $IPERF_PORT \
        -b ${MAX_BW_BPS} -t $STEP_DURATION -J 2>/dev/null" || echo '{}')
POST_HO_UL=$(echo "$POST_HO_UL_JSON" | python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read())
    e=d['end']
    bps=e['sum_sent']['bits_per_second']
    mb=e['sum_sent']['bytes']/1e6
    rtr=e['sum_sent'].get('retransmits',0)
    cpu_s=e['cpu_utilization_percent']['host_total']
    cpu_r=e['cpu_utilization_percent']['remote_total']
    print(f'ul_mbps={bps/1e6:.3f} mb={mb:.1f} rtr={rtr} cpu_s={cpu_s:.1f} cpu_r={cpu_r:.1f}')
except: print('parse error')
" 2>/dev/null || echo "post-HO UL failed")
log "  Post-HO UL (gnb2): $POST_HO_UL"

# ── PHASE 12: Post-HO system snapshot on gnb2 ────────────────────────────────
log "=== PHASE 12: Post-HO system snapshot on gnb2 ==="
ssh "$GNB2" "bash -s" << 'POSTSNAP'
COLLECT_DIR_GNB2="/tmp/ran_collect/ue50_gnb2"
TS=$(date +%H%M%S)

{
echo "=== [POST-HANDOVER] gnb2 CPU per-core ==="
cat /proc/stat | grep "^cpu[0-9]" | awk '{used=$2+$3+$4+$6+$7+$8; total=used+$5; printf "  %s: busy=%.1f%%\n", $1, (total>0 ? 100*used/total : 0)}' 2>/dev/null || true

echo ""
echo "=== [POST-HANDOVER] CPU frequencies ==="
for cpu_dir in /sys/devices/system/cpu/cpu*/cpufreq/; do
    cpu=$(basename "$(dirname "$cpu_dir")")
    freq_cur=$(cat "${cpu_dir}scaling_cur_freq" 2>/dev/null || echo "NA")
    freq_max=$(cat "${cpu_dir}cpuinfo_max_freq" 2>/dev/null || echo "NA")
    gov=$(cat "${cpu_dir}scaling_governor" 2>/dev/null || echo "NA")
    echo "  $cpu: cur=${freq_cur}Hz max=${freq_max}Hz gov=${gov}"
done

echo ""
echo "=== [POST-HANDOVER] RAPL CPU power ==="
for domain_dir in /sys/class/powercap/intel-rapl:*/; do
    name=$(cat "${domain_dir}name" 2>/dev/null || echo "$(basename $domain_dir)")
    uj1=$(cat "${domain_dir}energy_uj" 2>/dev/null || echo "NA")
    sleep 1
    uj2=$(cat "${domain_dir}energy_uj" 2>/dev/null || echo "NA")
    if [[ "$uj1" =~ ^[0-9]+$ ]] && [[ "$uj2" =~ ^[0-9]+$ ]]; then
        watts=$(awk "BEGIN{printf \"%.2f\", ($uj2-$uj1)/1e6}")
        echo "  $name: ${watts}W"
    else
        echo "  $name: energy_uj=$uj1"
    fi
done 2>/dev/null || echo "  RAPL not available"

echo ""
echo "=== [POST-HANDOVER] IRQ top-10 ==="
sort -t: -k2 -n -r /proc/interrupts 2>/dev/null | head -10 || true

echo ""
echo "=== [POST-HANDOVER] Softirq rates ==="
cat /proc/softirqs | head -20 || true

echo ""
echo "=== [POST-HANDOVER] srsenb UE50 process on gnb2 ==="
ps aux | grep '[s]rsenb.*ue50' || true

echo ""
echo "=== [POST-HANDOVER] Load average ==="
uptime || true

} > "$COLLECT_DIR_GNB2/gnb2_post_ho_system_snapshot.txt"
echo "Post-HO snapshot written."

# Copy gnb2 metrics CSV
cp /tmp/gnb2_ue50_metrics.csv "$COLLECT_DIR_GNB2/metrics/gnb2_ue50_metrics_full.csv" 2>/dev/null \
    && echo "gnb2 metrics CSV copied ($(wc -l < "$COLLECT_DIR_GNB2/metrics/gnb2_ue50_metrics_full.csv") rows)" \
    || echo "gnb2 metrics CSV not yet available"
POSTSNAP

# ── PHASE 13: Stop iperf3, collect gnb2 UE log ───────────────────────────────
log "=== PHASE 13: Cleanup and collect gnb2 UE log ==="
ssh "$CORE" "pkill -f 'iperf3.*-p $IPERF_PORT' 2>/dev/null || true"

ssh "$UEHOST1" "
    grep -E 'SNR|RSRP|RSRQ|MCS|BLER|PDCP|dl_brate|ul_brate|RRC|Network attach' \
        /tmp/ue_logs/ue50_gnb2_stdout.log 2>/dev/null | tail -80 \
        > $COLLECT_DIR_GNB2/ue50_gnb2_log_extract.txt || true
    echo 'UE50 gnb2 log extracted'
"

# ── PHASE 14: Final summary ───────────────────────────────────────────────────
log "=== PHASE 14: Final summary ==="
echo ""
echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║        UE50 Load-Balance Experiment — Complete                     ║"
echo "╠════════════════════════════════════════════════════════════════════╣"
echo "║  Pre-HO DL  (gnb1): $PRE_HO_DL"
echo "║  Post-HO DL (gnb2): $POST_HO_DL"
echo "║  Post-HO UL (gnb2): $POST_HO_UL"
echo "║  Post-HO ping      : $POST_HO_PING"
echo "║  UE50 IP on gnb2   : $UE50_GNB2_IP"
echo "╠════════════════════════════════════════════════════════════════════╣"
echo "║  Data directories:"
echo "║    Pre-HO / transition : gnb1:$COLLECT_DIR_LB"
echo "║    Post-HO gnb2        : gnb2:$COLLECT_DIR_GNB2"
echo "╠════════════════════════════════════════════════════════════════════╣"
echo "║  Next step: run scripts/collect_results_ue50.sh to download data  ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

log "Load-balance experiment complete."
