#!/bin/bash
# =============================================================================
# run_9ue_lb_proj.sh
# Self-contained 9-UE LB experiment runner using /proj NFS (disk-full workaround)
#
# Migrates UE40-49 from gNB1 → gNB2 and collects:
#   - RAPL CPU power (pkg0, dram) at 1s on gNB1 and gNB2
#   - System metrics: cpu_pct, cpu_freq, irq_rate, ctxt_rate, ipc, temp, ram
#   - gNB RAN metrics: nof_ue, dl_brate, ul_brate, sys_load, dl_nok (BLER)
#   - perf counters: IPC, cache-miss, instructions, cycles
#   - iperf3 throughput: pre-LB (500 Mbps) and post-LB per UE
#   - per-UE handover latency: detach_ms, attach_ms, HO_duration_ms
#
# All outputs go to WORKDIR (/proj NFS) — avoids /tmp disk-full on uehost1.
# Run from: uehost1 (pc808) OR Mac (orchestrates via SSH)
# =============================================================================
set -euo pipefail

GNB1="saish@pc818.emulab.net"
GNB2="saish@pc802.emulab.net"
CORE="saish@pc811.emulab.net"
UEHOST1="saish@pc808.emulab.net"

WORKDIR="/proj/ATLANTIC-eVISION/exp/loadbalance/tmp/ran_9ue_lb"
SCRIPTS="${WORKDIR}/scripts"
CONFIGS="${WORKDIR}/configs"
RESULTS="${WORKDIR}/results"
LOG="${WORKDIR}/experiment.log"
PHASE_FILE="${WORKDIR}/phase.txt"

SSH="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

UE_START=40; UE_END=49

PHASE1_S=60   # baseline
PHASE3_S=60   # pre-LB 500 Mbps hold
DETACH_GAP=3  # seconds between each UE detach
ATTACH_WAIT=30
PHASE6_S=90   # post-LB hold

TOTAL_S=$(( PHASE1_S + 30 + PHASE3_S + 10*DETACH_GAP + 30 + 10*(ATTACH_WAIT+ATTACH_GAP) + PHASE6_S + 60 ))
ATTACH_GAP=2

mkdir -p "${RESULTS}"
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "${LOG}"; }
die() { log "FATAL: $*"; exit 1; }

set_phase() {
    echo "$1" > "${PHASE_FILE}"
    for h in "$GNB1" "$GNB2" "$CORE" "$UEHOST1"; do
        ssh $SSH "$h" "echo '$1' > ${PHASE_FILE}" 2>/dev/null || true
    done
    log "━━━ Phase: $1 ━━━"
}

stop_collectors() {
    log "Stopping collectors..."
    for h in "$GNB1" "$GNB2" "$CORE" "$UEHOST1"; do
        ssh $SSH "$h" "pkill -f collect_system_metrics || true; pkill -f collect_gnb_metrics || true; pkill -f collect_power || true; pkill -f collect_rich_gnb || true; pkill -f deep_sysmon || true; pkill -f collect_perf_ipc || true; pkill -f collect_ue40_49 || true" 2>/dev/null || true
    done
}
trap stop_collectors EXIT

log "============================================================"
log "  9-UE LB Experiment  UE${UE_START}-${UE_END}  WORKDIR=${WORKDIR}"
log "  Estimated total runtime: ~${TOTAL_S}s"
log "============================================================"

# ── STEP 0: Verify node state ─────────────────────────────────
log "--- Verifying UE40-49 are attached to gNB1 ---"
ssh $SSH "$UEHOST1" "ip netns list | grep -c ue" 2>/dev/null | xargs -I{} log "  uehost1 netns count: {}" || true

# ── STEP 1: Start all collectors ─────────────────────────────
log "--- Starting collectors on all nodes ---"

# System metrics: every node, 5s interval
for h in "$GNB1" "$GNB2" "$CORE" "$UEHOST1"; do
    NODE=$(ssh $SSH "$h" "hostname -s" 2>/dev/null || echo "unknown")
    ssh $SSH "$h" "nohup bash ${SCRIPTS}/collect_system_metrics.sh 5 ${TOTAL_S} > ${WORKDIR}/sysmet_${NODE}.log 2>&1 </dev/null &" 2>/dev/null || \
        log "WARN: sysmet failed on $h"
done

# gNB metrics: 5s on gnb1 (UE1-50), gnb2 (UE40-49 slots)
ssh $SSH "$GNB1" "nohup bash ${SCRIPTS}/collect_gnb_metrics.sh 5 ${TOTAL_S} gnb1 1 50 > ${WORKDIR}/gnbmet_gnb1.log 2>&1 </dev/null &" 2>/dev/null || true
ssh $SSH "$GNB2" "nohup bash ${SCRIPTS}/collect_gnb_metrics.sh 5 ${TOTAL_S} gnb2 40 49 > ${WORKDIR}/gnbmet_gnb2.log 2>&1 </dev/null &" 2>/dev/null || true

# RAPL power: 1s on gnb1 + gnb2
ssh $SSH "$GNB1" "nohup sudo bash ${SCRIPTS}/collect_power.sh ${TOTAL_S} 1 ${WORKDIR}/power_gnb1.csv > ${WORKDIR}/power_gnb1.log 2>&1 </dev/null &" 2>/dev/null || \
    log "WARN: RAPL power failed on gnb1 (check sudo)"
ssh $SSH "$GNB2" "nohup sudo bash ${SCRIPTS}/collect_power.sh ${TOTAL_S} 1 ${WORKDIR}/power_gnb2.csv > ${WORKDIR}/power_gnb2.log 2>&1 </dev/null &" 2>/dev/null || \
    log "WARN: RAPL power failed on gnb2 (check sudo)"

# Deep sysmon (per-process CPU/mem, 2s) on gnb1 + gnb2
ssh $SSH "$GNB1" "nohup python3 ${SCRIPTS}/deep_sysmon.py ${TOTAL_S} 2 srsenb ${WORKDIR}/deep_sysmon_gnb1.csv > ${WORKDIR}/deep_sysmon_gnb1.log 2>&1 </dev/null &" 2>/dev/null || true
ssh $SSH "$GNB2" "nohup python3 ${SCRIPTS}/deep_sysmon.py ${TOTAL_S} 2 srsenb ${WORKDIR}/deep_sysmon_gnb2.csv > ${WORKDIR}/deep_sysmon_gnb2.log 2>&1 </dev/null &" 2>/dev/null || true

# perf IPC (5s) on gnb1 + gnb2
if ssh $SSH "$GNB1" "test -f ${SCRIPTS}/collect_perf_ipc.sh" 2>/dev/null; then
    ssh $SSH "$GNB1" "nohup bash ${SCRIPTS}/collect_perf_ipc.sh gnb1 5 > ${WORKDIR}/perfipc_gnb1.log 2>&1 </dev/null &" 2>/dev/null || true
    ssh $SSH "$GNB2" "nohup bash ${SCRIPTS}/collect_perf_ipc.sh gnb2 5 > ${WORKDIR}/perfipc_gnb2.log 2>&1 </dev/null &" 2>/dev/null || true
fi

# Multi-UE handover monitor on uehost1
ssh $SSH "$UEHOST1" "nohup bash ${SCRIPTS}/collect_ue40_49_handover.sh 500 $(( PHASE3_S + 10*DETACH_GAP + 10*(ATTACH_WAIT+ATTACH_GAP) + PHASE6_S + 60 )) > ${WORKDIR}/handover_9ue.log 2>&1 </dev/null &" 2>/dev/null || \
    log "WARN: handover monitor failed to start on uehost1"

log "All collectors running. Warming up 5s..."
sleep 5

# ── PHASE 1: Baseline — 50 UEs on gNB1 ─────────────────────
set_phase "phase1_gnb1_baseline_50ue"
log "Phase 1: Baseline ${PHASE1_S}s — 50 UEs on gNB1 with background traffic"

# Light background iperf for UE1-10 to create realistic load
ssh $SSH "$UEHOST1" "
    for i in 1 2 3 4 5 6 7 8 9 10; do
        ip netns exec ue\${i} iperf3 -c 10.10.1.1 -u -b 20M -t ${PHASE1_S} -J > ${WORKDIR}/iperf_baseline_ue\${i}.json 2>/dev/null &
    done
    echo baseline_iperf_started
" 2>/dev/null || log "WARN: baseline iperf failed"

sleep "${PHASE1_S}"
log "Phase 1 baseline complete."

# ── PHASE 2: Ramp UE40-49 to 500 Mbps ──────────────────────
set_phase "phase2_ramp_500mbps_prelb"
log "Phase 2: Ramping UE40-49 to 500 Mbps..."

PHASE3_PLUS=$(( PHASE3_S + 30 ))
ssh $SSH "$UEHOST1" "
    for i in 40 41 42 43 44 45 46 47 48 49; do
        ip netns exec ue\${i} iperf3 -c 10.10.1.1 -u -b 500M -t ${PHASE3_PLUS} -J > ${WORKDIR}/iperf_prelb_ue\${i}.json 2>/dev/null &
    done
    echo prelb_iperf_started
" 2>/dev/null || log "WARN: pre-LB iperf failed"

log "Phase 2 ramp launched."

# ── PHASE 3: Hold 500 Mbps pre-LB ──────────────────────────
set_phase "phase3_hold_500mbps_prelb"
log "Phase 3: Holding 500 Mbps for ${PHASE3_S}s — capturing Pactive for Eq.4"
sleep "${PHASE3_S}"
log "Phase 3 pre-LB hold complete."

# ── PHASE 4: Staggered detach UE40-49 from gNB1 ─────────────
set_phase "phase4_lb_trigger_detach"
LB_TRIGGER_TS=$(date '+%s%3N')
log "Phase 4: LB trigger at ${LB_TRIGGER_TS}ms — staggered detach UE40-49..."

echo "lb_trigger_ts_ms=${LB_TRIGGER_TS}" > "${WORKDIR}/lb_trigger_9ue.txt"

# Array to track detach timestamps
declare -A DETACH_TS

for i in 40 41 42 43 44 45 46 47 48 49; do
    log "  Detaching UE${i}..."
    ssh $SSH "$UEHOST1" "pkill -SIGTERM -f 'srsue.*ue${i}[^0-9]' 2>/dev/null || pkill -SIGTERM -f 'srsue.*ue${i}\.conf' 2>/dev/null || true; ip netns exec ue${i} pkill -f iperf3 2>/dev/null || true" 2>/dev/null || true
    DETACH_TS[$i]=$(date '+%s%3N')
    log "  UE${i} detach at ${DETACH_TS[$i]}ms"
    sleep "${DETACH_GAP}"
done

log "Phase 4 — all detach signals sent."
sleep 5  # allow gNB1 RRC releases to complete

# ── PHASE 5: Start gNB2 slots + reconnect UEs ──────────────
set_phase "phase5_handover_window"
log "Phase 5: Adding gNB2 IP aliases and starting enb slots..."

# Add IP aliases 10.10.1.240-249 on gNB2
ssh $SSH "$GNB2" "
    DEV=\$(ip route show default | awk '/default/{print \$5}' | head -1)
    [ -z \"\$DEV\" ] && DEV=enp6s0f3
    for j in 240 241 242 243 244 245 246 247 248 249; do
        ip=\"10.10.1.\${j}\"
        ip addr show dev \$DEV 2>/dev/null | grep -q \"\${ip}\" || sudo ip addr add \${ip}/24 dev \$DEV 2>/dev/null && echo \"alias \${ip} ok\"
    done
" 2>/dev/null || log "WARN: gnb2 IP alias setup failed"

sleep 2

declare -A ATTACH_TS
declare -A HO_MS

for i in 40 41 42 43 44 45 46 47 48 49; do
    log "  Starting gNB2 enb slot for UE${i}..."
    ssh $SSH "$GNB2" "
        mkdir -p /tmp/gnb2_logs
        ps aux | grep -q '[s]rsenb.*enb_ue${i}' || sudo srsenb /etc/srsenb/enb_ue${i}.conf >> /tmp/gnb2_logs/ue${i}.log 2>&1 &
        sleep 1 && echo gnb2_slot_ue${i}_started
    " 2>/dev/null || log "WARN: gnb2 slot for UE${i} failed"

    sleep 1

    # Clean and re-create netns
    ssh $SSH "$UEHOST1" "
        ip netns del ue${i} 2>/dev/null || true
        ip netns add ue${i} 2>/dev/null || true
        echo netns_ue${i}_ready
    " 2>/dev/null || true

    # Start srsue pointing at gNB2
    UE_CONF="${CONFIGS}/ues/ue${i}_gnb2.conf"
    ssh $SSH "$UEHOST1" "
        test -f ${UE_CONF} || { echo MISSING_CONF_${i}; exit 1; }
        nohup srsue ${UE_CONF} --log.filename=${WORKDIR}/ue${i}_gnb2.log >> ${WORKDIR}/ue${i}_gnb2_stdout.log 2>&1 </dev/null &
        echo ue${i}_srsue_started
    " 2>/dev/null || log "WARN: srsue start failed for UE${i}"

    # Wait for tun to come UP (max ATTACH_WAIT seconds)
    ATTACHED=0
    for s in $(seq 1 "${ATTACH_WAIT}"); do
        sleep 1
        STATE=$(ssh $SSH "$UEHOST1" "ip netns exec ue${i} ip link show tun_srsue${i} 2>/dev/null | grep -c UP || echo 0" 2>/dev/null || echo 0)
        if [ "${STATE}" = "1" ]; then
            ATTACH_TS[$i]=$(date '+%s%3N')
            HO_MS[$i]=$(( ${ATTACH_TS[$i]} - ${DETACH_TS[$i]} ))
            log "  *** UE${i} ATTACHED to gNB2 in ${HO_MS[$i]}ms ***"
            ATTACHED=1
            break
        fi
    done
    [ "${ATTACHED}" = "0" ] && { ATTACH_TS[$i]="TIMEOUT"; HO_MS[$i]="TIMEOUT"; log "  WARN: UE${i} did not attach within ${ATTACH_WAIT}s"; }

    sleep "${ATTACH_GAP}"
done

log "Phase 5 handover window complete."

# ── PHASE 6: Post-LB steady state ───────────────────────────
set_phase "phase6_post_lb_steady_state"
log "Phase 6: Post-LB hold ${PHASE6_S}s — gNB1:40UE gNB2:9UE"
log "  Capturing Pswitched (Eq.4) and post-LB power model data"

# Post-LB iperf on migrated UEs
for i in 40 41 42 43 44 45 46 47 48 49; do
    [ "${ATTACH_TS[$i]:-TIMEOUT}" = "TIMEOUT" ] && continue
    ssh $SSH "$UEHOST1" "ip netns exec ue${i} iperf3 -c 10.10.1.1 -u -b 500M -t ${PHASE6_S} -J > ${WORKDIR}/iperf_postlb_ue${i}.json 2>/dev/null &" 2>/dev/null || true
done

sleep "${PHASE6_S}"
log "Phase 6 post-LB hold complete."

# ── DONE — stop collectors ───────────────────────────────────
set_phase "collection_complete"
log "Collection complete. Stopping collectors..."
stop_collectors
sleep 3

# ── Write per-UE handover summary ────────────────────────────
{
    echo "=== 9-UE Load-Balancing Handover Summary ==="
    echo "Run timestamp   : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "LB trigger (ms) : ${LB_TRIGGER_TS}"
    echo ""
    echo "Per-UE Handover Latencies:"
    TOTAL_HO=0; N_HO=0
    for i in 40 41 42 43 44 45 46 47 48 49; do
        ho="${HO_MS[$i]:-N/A}"
        echo "  UE${i}: detach=${DETACH_TS[$i]:-N/A}ms  attach=${ATTACH_TS[$i]:-N/A}ms  HO_ms=${ho}"
        [[ "$ho" =~ ^[0-9]+$ ]] && TOTAL_HO=$(( TOTAL_HO + ho )) && N_HO=$(( N_HO + 1 ))
    done
    if (( N_HO > 0 )); then
        AVG_HO=$(python3 -c "print(f'{${TOTAL_HO} / ${N_HO}:.1f}')")
        echo ""
        echo "Avg HO latency     : ${AVG_HO} ms"
        echo "Successful HOs     : ${N_HO}/10"
    fi
    echo ""
    echo "=== Paper Equations — Data Mapping ==="
    echo "Eq.2 P=α·load^β+γ    → power_gnb1.csv + gnb_metrics_gnb1.csv sys_load"
    echo "Eq.3 Ptotal=Pbase+... → power_gnb1.csv phase3 vs phase6"
    echo "                         NaU: 50→40 on gnb1; 0→9 on gnb2"
    echo "Eq.4 Psaved=Pact-Psw  → Pactive=phase3, Pswitched=phase6"
    echo "KF-3 NC CPU savings   → system_metrics.csv gnb1 cpu_pct phase3 vs phase6"
    echo "KF-4 Marginal PaU     → power_gnb2.csv pre-LB vs post-LB"
    echo ""
    echo "=== Output Files ==="
    ls -lh "${WORKDIR}"/*.csv "${WORKDIR}"/*.json 2>/dev/null || echo "no files yet"
} > "${WORKDIR}/lb9ue_summary.txt"

cat "${WORKDIR}/lb9ue_summary.txt" | tee -a "${LOG}"

log ""
log "=== EXPERIMENT COMPLETE ==="
log "Results dir: ${WORKDIR}"
log "CSV files:"
ls "${WORKDIR}"/*.csv 2>/dev/null | tee -a "${LOG}" || log "  (none yet — check logs)"
