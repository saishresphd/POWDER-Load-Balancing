#!/usr/bin/env bash
# ============================================================
# run_ue51_lb_experiment.sh
# Master orchestrator — UE51 load-balancing experiment
#
# Phases:
#   Phase 1  (60s)  — Baseline: 50 UEs on gNB1, all collectors running
#   Phase 2         — Connect UE51 to gNB1 from uehost2
#   Phase 3         — Ramp ALL 51 UEs to 500 Mbps
#   Phase 4  (60s)  — Hold at 500 Mbps (peak-load steady state)
#   Phase 5         — Trigger LB: mark UE51 for migration, detach from gNB1
#   Phase 6         — Handover window: monitor detach → attach on gNB2
#   Phase 7  (60s)  — UE51 active on gNB2, post-LB steady state
#   Done            — Stop collectors, pull results, write summary
#
# Run on: uehost1 (pc808)
# Usage : bash run_ue51_lb_experiment.sh
# ============================================================
set -euo pipefail

# ── Argument parsing ─────────────────────────────────────────────────────────
SKIP_UE_START=0
SKIP_IPERF_RAMP=0
for arg in "$@"; do
    case "$arg" in
        --skip-ue-start)   SKIP_UE_START=1 ;;
        --skip-iperf-ramp) SKIP_IPERF_RAMP=1 ;;
    esac
done

# ── Node addresses ──────────────────────────────────────────
CORE_HOST="saish@10.10.1.1"
GNB1_HOST="saish@10.10.1.2"
GNB2_HOST="saish@10.10.1.3"
UEHOST1_HOST="saish@10.10.1.4"   # self (uehost1 = pc808)
UEHOST2_HOST="saish@10.10.1.5"

GNB1_IP="10.10.1.2"
GNB2_IP="10.10.1.3"
UEHOST2_IP="10.10.1.5"

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

# ── Timing (seconds) ────────────────────────────────────────
PHASE1_BASELINE_S=60
PHASE4_HOLD_S=60
PHASE7_POST_LB_S=60
HANDOVER_TIMEOUT_S=120    # max wait for UE51 to re-attach to gNB2

# ── Paths ───────────────────────────────────────────────────
COLLECT_DIR="/tmp/ran_collect"
SCRIPTS_DIR="$COLLECT_DIR/scripts"
CONFIGS_DIR="$COLLECT_DIR/configs"
LOG="$COLLECT_DIR/orchestrator.log"
PHASE_FILE="$COLLECT_DIR/phase.txt"
RESULTS_DIR="$COLLECT_DIR/results"
HANDOVER_SUMMARY="$COLLECT_DIR/ue51_handover_summary.txt"
EXPERIMENT_SUMMARY="$COLLECT_DIR/experiment_summary.txt"

# ── Script names (staged to SCRIPTS_DIR on each node) ───────
SYSMETRICS_SCRIPT="collect_system_metrics.sh"
GNB_METRICS_SCRIPT="collect_gnb_metrics.sh"
RICH_GNB_SCRIPT="collect_rich_gnb.sh"
POWER_SCRIPT="collect_power.sh"
DEEP_SYSMON_SCRIPT="deep_sysmon.py"
IPERF_RAMP_SCRIPT="run_iperf_ramp.sh"
IPERF_500_SCRIPT="run_iperf_500mbps.sh"
HANDOVER_SCRIPT="collect_ue51_handover.sh"

# ── UE51 config file names ───────────────────────────────────
UE51_GNB1_CONF="ue51.conf"           # exists at configs/ues/ue51.conf on repo
UE51_GNB2_CONF="ue51_gnb2.conf"      # new: configs/ues/ue51_gnb2.conf

# ── Collector background PIDs (tracked for cleanup) ─────────
declare -a COLLECTOR_PIDS=()

# ── Logging ─────────────────────────────────────────────────
mkdir -p "$COLLECT_DIR" "$RESULTS_DIR"
log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" | tee -a "$LOG"; }
die() { log "FATAL: $*"; exit 1; }

# ── Phase broadcaster ────────────────────────────────────────
set_phase() {
    local phase="$1"
    echo "$phase" > "$PHASE_FILE"
    for host in "$GNB1_HOST" "$GNB2_HOST" "$UEHOST2_HOST" "$CORE_HOST"; do
        ssh $SSH_OPTS "$host" "mkdir -p $COLLECT_DIR; echo '$phase' > $PHASE_FILE" 2>/dev/null &
    done
    wait
    log "━━━ Phase → $phase ━━━"
}

# ── Stage files to a remote node ────────────────────────────
stage_scripts_to() {
    local host="$1"
    log "  Staging scripts → $host"
    ssh $SSH_OPTS "$host" "mkdir -p $SCRIPTS_DIR $CONFIGS_DIR $COLLECT_DIR"
    # Stage every script and config the node may need
    for f in \
        "$COLLECT_DIR/$SYSMETRICS_SCRIPT" \
        "$COLLECT_DIR/$GNB_METRICS_SCRIPT" \
        "$COLLECT_DIR/$RICH_GNB_SCRIPT" \
        "$COLLECT_DIR/$POWER_SCRIPT" \
        "$COLLECT_DIR/$DEEP_SYSMON_SCRIPT" \
        "$COLLECT_DIR/$IPERF_RAMP_SCRIPT" \
        "$COLLECT_DIR/$IPERF_500_SCRIPT" \
        "$COLLECT_DIR/$HANDOVER_SCRIPT"; do
        [ -f "$f" ] && scp $SSH_OPTS "$f" "$host:$COLLECT_DIR/" 2>/dev/null || true
    done
}

# ── Remote nohup launcher ────────────────────────────────────
remote_nohup() {
    # remote_nohup <ssh_host> <cmd> <logfile>
    local host="$1" cmd="$2" logfile="$3"
    ssh $SSH_OPTS "$host" \
        "nohup bash -c '$cmd' >> '$logfile' 2>&1 </dev/null &"
}

# ── Kill all background collectors on all nodes ──────────────
stop_all_collectors() {
    log "Stopping all collectors..."
    for pid in "${COLLECTOR_PIDS[@]:-}"; do
        kill "$pid" 2>/dev/null || true
    done
    for host in "$GNB1_HOST" "$GNB2_HOST" "$UEHOST2_HOST" "$CORE_HOST"; do
        ssh $SSH_OPTS "$host" \
            "pkill -f $SYSMETRICS_SCRIPT; pkill -f $GNB_METRICS_SCRIPT; \
             pkill -f $RICH_GNB_SCRIPT; pkill -f $POWER_SCRIPT; \
             pkill -f $DEEP_SYSMON_SCRIPT; pkill -f $HANDOVER_SCRIPT" \
            2>/dev/null || true
    done
    pkill -f "$SYSMETRICS_SCRIPT" 2>/dev/null || true
    pkill -f "$IPERF_500_SCRIPT"  2>/dev/null || true
    pkill -f "$HANDOVER_SCRIPT"   2>/dev/null || true
    log "Collectors stopped."
}
trap stop_all_collectors EXIT

# ══════════════════════════════════════════════════════════════
# SETUP: Verify scripts are present locally
# ══════════════════════════════════════════════════════════════
log "=== UE51 Load-Balancing Experiment ==="
log "Node layout: core=$CORE_HOST  gnb1=$GNB1_HOST  gnb2=$GNB2_HOST"
log "             uehost1=self  uehost2=$UEHOST2_HOST"

for req in \
    "$COLLECT_DIR/$SYSMETRICS_SCRIPT" \
    "$COLLECT_DIR/$GNB_METRICS_SCRIPT" \
    "$COLLECT_DIR/$IPERF_500_SCRIPT" \
    "$COLLECT_DIR/$HANDOVER_SCRIPT"; do
    [ -f "$req" ] || die "Required script not found: $req  (run deploy step first)"
done

# Stage all scripts to remote nodes
log "Staging scripts to remote nodes..."
for host in "$GNB1_HOST" "$GNB2_HOST" "$UEHOST2_HOST" "$CORE_HOST"; do
    stage_scripts_to "$host" &
done
wait
log "Staging complete."

# ══════════════════════════════════════════════════════════════
# START COLLECTORS  (run throughout ALL phases)
# ══════════════════════════════════════════════════════════════
log "--- Starting background collectors on ALL nodes ---"

TOTAL_DURATION_S=$(( PHASE1_BASELINE_S + 30 + 300 + PHASE4_HOLD_S + 30 + HANDOVER_TIMEOUT_S + PHASE7_POST_LB_S + 120 ))

# ── System metrics (5s interval) on every node ──────────────
for host in "$GNB1_HOST" "$GNB2_HOST" "$UEHOST2_HOST" "$CORE_HOST"; do
    remote_nohup "$host" \
        "bash $COLLECT_DIR/$SYSMETRICS_SCRIPT 5 $TOTAL_DURATION_S" \
        "$COLLECT_DIR/sysmetrics.log"
done
nohup bash "$COLLECT_DIR/$SYSMETRICS_SCRIPT" 5 "$TOTAL_DURATION_S" \
    >> "$COLLECT_DIR/sysmetrics_uehost1.log" 2>&1 &
COLLECTOR_PIDS+=($!)

# ── gNB metrics (5s interval) on gNB1 + gNB2 ───────────────
remote_nohup "$GNB1_HOST" \
    "bash $COLLECT_DIR/$GNB_METRICS_SCRIPT 5 $TOTAL_DURATION_S gnb1 1 51" \
    "$COLLECT_DIR/gnb1_collect.log"
remote_nohup "$GNB2_HOST" \
    "bash $COLLECT_DIR/$GNB_METRICS_SCRIPT 5 $TOTAL_DURATION_S gnb2 51 51" \
    "$COLLECT_DIR/gnb2_collect.log"

# ── Rich gNB metrics (if script present) on gNB1 + gNB2 ─────
if ssh $SSH_OPTS "$GNB1_HOST" "test -f $COLLECT_DIR/$RICH_GNB_SCRIPT" 2>/dev/null; then
    remote_nohup "$GNB1_HOST" \
        "bash $COLLECT_DIR/$RICH_GNB_SCRIPT 5 $TOTAL_DURATION_S gnb1 1 51" \
        "$COLLECT_DIR/rich_gnb1.log"
    remote_nohup "$GNB2_HOST" \
        "bash $COLLECT_DIR/$RICH_GNB_SCRIPT 5 $TOTAL_DURATION_S gnb2 51 51" \
        "$COLLECT_DIR/rich_gnb2.log"
fi

# ── RAPL power (1s interval, needs sudo) on gNB1 + gNB2 ─────
if ssh $SSH_OPTS "$GNB1_HOST" "test -f $COLLECT_DIR/$POWER_SCRIPT" 2>/dev/null; then
    remote_nohup "$GNB1_HOST" \
        "sudo bash $COLLECT_DIR/$POWER_SCRIPT 1 $TOTAL_DURATION_S" \
        "$COLLECT_DIR/power_gnb1.log"
    remote_nohup "$GNB2_HOST" \
        "sudo bash $COLLECT_DIR/$POWER_SCRIPT 1 $TOTAL_DURATION_S" \
        "$COLLECT_DIR/power_gnb2.log"
fi

# ── Deep sysmon (2s interval) on gNB1 + gNB2 ────────────────
if ssh $SSH_OPTS "$GNB1_HOST" "test -f $COLLECT_DIR/$DEEP_SYSMON_SCRIPT" 2>/dev/null; then
    remote_nohup "$GNB1_HOST" \
        "python3 $COLLECT_DIR/$DEEP_SYSMON_SCRIPT $TOTAL_DURATION_S 2 srsenb $COLLECT_DIR/deep_sysmon_gnb1.csv" \
        "$COLLECT_DIR/deep_sysmon_gnb1.log"
    remote_nohup "$GNB2_HOST" \
        "python3 $COLLECT_DIR/$DEEP_SYSMON_SCRIPT $TOTAL_DURATION_S 2 srsenb $COLLECT_DIR/deep_sysmon_gnb2.csv" \
        "$COLLECT_DIR/deep_sysmon_gnb2.log"
fi

# ── UE51 handover monitor on uehost2 ────────────────────────
HANDOVER_TOTAL_S=$(( HANDOVER_TIMEOUT_S + PHASE7_POST_LB_S + 60 ))
remote_nohup "$UEHOST2_HOST" \
    "bash $COLLECT_DIR/$HANDOVER_SCRIPT 500 $HANDOVER_TOTAL_S" \
    "$COLLECT_DIR/handover_monitor.log"

log "All background collectors launched."
sleep 5   # let collectors stabilise

# ══════════════════════════════════════════════════════════════
# PHASE 1: Baseline — 50 UEs on gNB1
# ══════════════════════════════════════════════════════════════
set_phase "phase1_gnb1_baseline"
log "Phase 1: Verifying UE1-50 attached on gNB1..."

ATTACHED=$(ssh $SSH_OPTS "$GNB1_HOST" \
    "tail -1 $COLLECT_DIR/gnb_metrics_raw_gnb1.csv 2>/dev/null | cut -d';' -f2 || echo 0" \
    2>/dev/null || echo "0")
log "  gNB1 current nof_ue = $ATTACHED"

log "Phase 1: Running initial iperf ramp (20 Mbps) on UE1-50..."
bash "$COLLECT_DIR/$IPERF_RAMP_SCRIPT" 50 2>&1 | tee -a "$LOG" || true

log "Phase 1: Holding baseline for ${PHASE1_BASELINE_S}s..."
sleep "$PHASE1_BASELINE_S"
log "Phase 1 baseline complete."

if (( SKIP_UE_START == 0 )); then
# ══════════════════════════════════════════════════════════════
# PHASE 2: Connect UE51 to gNB1
# ══════════════════════════════════════════════════════════════
set_phase "phase2_ue51_attach_gnb1"
log "Phase 2: Starting UE51 on uehost2, connecting to gNB1..."

# Copy the corrected enb_ue51.conf to gNB1 (rx_port fix: 10.10.1.4→10.10.1.5)
if [ -f "$CONFIGS_DIR/gnb1/enb_ue51.conf" ]; then
    scp $SSH_OPTS "$CONFIGS_DIR/gnb1/enb_ue51.conf" \
        "$GNB1_HOST:/etc/srsran/enb_ue51.conf" 2>/dev/null || \
    scp $SSH_OPTS "$CONFIGS_DIR/gnb1/enb_ue51.conf" \
        "$GNB1_HOST:$COLLECT_DIR/enb_ue51.conf" 2>/dev/null || true
fi

# Copy UE51→gNB1 UE config to uehost2
if [ -f "$CONFIGS_DIR/ues/$UE51_GNB1_CONF" ]; then
    scp $SSH_OPTS "$CONFIGS_DIR/ues/$UE51_GNB1_CONF" \
        "$UEHOST2_HOST:$COLLECT_DIR/$UE51_GNB1_CONF" 2>/dev/null || true
fi

# Reload gNB1 enb_ue51 slot (SIGHUP or restart if needed)
log "  Reloading UE51 slot on gNB1..."
ssh $SSH_OPTS "$GNB1_HOST" \
    "pkill -f 'srsue.*ue51' 2>/dev/null || true; sleep 1" 2>/dev/null || true

# Start UE51 on uehost2 pointing at gNB1
UE51_START_TS=$(date '+%s%3N')
ssh $SSH_OPTS "$UEHOST2_HOST" \
    "sudo ip netns add ue51 2>/dev/null || true; \
     nohup srsue $COLLECT_DIR/$UE51_GNB1_CONF \
         --log.filename=$COLLECT_DIR/ue51_gnb1.log \
         >> $COLLECT_DIR/ue51_gnb1_stdout.log 2>&1 </dev/null &
     echo 'UE51 started on gNB1'" 2>&1 | tee -a "$LOG"

log "  Waiting for UE51 to attach (max 30s)..."
ATTACHED51=0
for i in $(seq 1 30); do
    sleep 1
    TUN=$(ssh $SSH_OPTS "$UEHOST2_HOST" \
        "ip netns exec ue51 ip link show tun_srsue 2>/dev/null | grep -c UP || echo 0" \
        2>/dev/null || echo "0")
    if (( TUN >= 1 )); then
        ATTACHED51=1
        log "  UE51 attached to gNB1 (tun UP) after ${i}s"
        break
    fi
done
if (( ATTACHED51 == 0 )); then
    log "WARNING: UE51 did not attach within 30s — continuing anyway"
fi

log "Phase 2 complete. UE51 on gNB1."
fi  # end SKIP_UE_START

if (( SKIP_IPERF_RAMP == 0 )); then
# ══════════════════════════════════════════════════════════════
# PHASE 3: Ramp all 51 UEs to 500 Mbps
# ══════════════════════════════════════════════════════════════
set_phase "phase3_ramp_500mbps"
log "Phase 3: Ramping 51 UEs → 500 Mbps (13 steps, 15s each)..."

# Run iperf ramp — script handles UE1-50 locally, UE51 via SSH to uehost2
nohup bash "$COLLECT_DIR/$IPERF_500_SCRIPT" 51 15 \
    >> "$COLLECT_DIR/iperf_500_ramp.log" 2>&1 &
RAMP_PID=$!
wait "$RAMP_PID" || log "WARNING: iperf ramp exited non-zero"
log "Phase 3 ramp complete."
fi  # end SKIP_IPERF_RAMP

# ══════════════════════════════════════════════════════════════
# PHASE 4: Hold at 500 Mbps — peak-load steady state
# ══════════════════════════════════════════════════════════════
set_phase "phase4_hold_500mbps"
log "Phase 4: Holding 500 Mbps for ${PHASE4_HOLD_S}s (peak-load steady state)..."
sleep "$PHASE4_HOLD_S"
log "Phase 4 hold complete."

# ══════════════════════════════════════════════════════════════
# PHASE 5: Trigger load-balance — detach UE51 from gNB1
# ══════════════════════════════════════════════════════════════
set_phase "phase5_lb_trigger"
LB_TRIGGER_TS=$(date '+%s%3N')
log "Phase 5: Load-balance trigger at ${LB_TRIGGER_TS}ms — stopping UE51 on gNB1..."

# Record trigger event in handover CSV directory
echo "lb_trigger_ts_ms=$LB_TRIGGER_TS" > "$COLLECT_DIR/lb_trigger.txt"
ssh $SSH_OPTS "$UEHOST2_HOST" \
    "echo 'lb_trigger_ts_ms=$LB_TRIGGER_TS' > $COLLECT_DIR/lb_trigger.txt" \
    2>/dev/null || true

# Stop UE51 srsue process on uehost2 (detach from gNB1)
ssh $SSH_OPTS "$UEHOST2_HOST" \
    "pkill -SIGTERM -f 'srsue.*$UE51_GNB1_CONF' 2>/dev/null || \
     pkill -SIGTERM -f 'srsue.*ue51' 2>/dev/null || true" \
    2>/dev/null || true

DETACH_TS=$(date '+%s%3N')
log "  UE51 detach signal sent at ${DETACH_TS}ms"
log "  Detach latency from trigger: $(( DETACH_TS - LB_TRIGGER_TS )) ms"

# Brief pause for gNB1 RRC release
sleep 3

log "Phase 5 complete — UE51 detached from gNB1."

# ══════════════════════════════════════════════════════════════
# PHASE 6: Handover window — reattach UE51 to gNB2
# ══════════════════════════════════════════════════════════════
set_phase "phase6_handover_window"
log "Phase 6: Reconnecting UE51 to gNB2 (handover window)..."

# Copy UE51→gNB2 config to uehost2
if [ -f "$CONFIGS_DIR/ues/$UE51_GNB2_CONF" ]; then
    scp $SSH_OPTS "$CONFIGS_DIR/ues/$UE51_GNB2_CONF" \
        "$UEHOST2_HOST:$COLLECT_DIR/$UE51_GNB2_CONF" 2>/dev/null || true
fi

# Brief pause before reconnect (let gNB2 enb slot be ready)
sleep 2

RECONNECT_START_TS=$(date '+%s%3N')
ssh $SSH_OPTS "$UEHOST2_HOST" \
    "sudo ip netns del ue51 2>/dev/null || true; \
     sudo ip netns add ue51 2>/dev/null || true; \
     nohup srsue $COLLECT_DIR/$UE51_GNB2_CONF \
         --log.filename=$COLLECT_DIR/ue51_gnb2.log \
         >> $COLLECT_DIR/ue51_gnb2_stdout.log 2>&1 </dev/null &
     echo 'UE51 started on gNB2'" 2>&1 | tee -a "$LOG"

log "  UE51 connecting to gNB2. Waiting for attach (max ${HANDOVER_TIMEOUT_S}s)..."
ATTACH51_GNB2=0
for i in $(seq 1 "$HANDOVER_TIMEOUT_S"); do
    sleep 1
    TUN=$(ssh $SSH_OPTS "$UEHOST2_HOST" \
        "ip netns exec ue51 ip link show tun_srsue 2>/dev/null | grep -c UP || echo 0" \
        2>/dev/null || echo "0")
    if (( TUN >= 1 )); then
        ATTACH_TS=$(date '+%s%3N')
        ATTACH51_GNB2=1
        HANDOVER_DURATION_MS=$(( ATTACH_TS - DETACH_TS ))
        E2E_DURATION_MS=$(( ATTACH_TS - LB_TRIGGER_TS ))
        log "  *** UE51 ATTACHED to gNB2 after ${i}s ***"
        log "  Handover duration (detach→attach): ${HANDOVER_DURATION_MS} ms"
        log "  E2E LB duration  (trigger→attach): ${E2E_DURATION_MS} ms"
        break
    fi
done

if (( ATTACH51_GNB2 == 0 )); then
    ATTACH_TS=$(date '+%s%3N')
    HANDOVER_DURATION_MS=$(( ATTACH_TS - DETACH_TS ))
    E2E_DURATION_MS=$(( ATTACH_TS - LB_TRIGGER_TS ))
    log "WARNING: UE51 did not confirm attach within ${HANDOVER_TIMEOUT_S}s"
fi

log "Phase 6 handover window complete."

# ══════════════════════════════════════════════════════════════
# PHASE 7: Post-LB steady state on gNB2
# ══════════════════════════════════════════════════════════════
set_phase "phase7_gnb2_post_lb"
log "Phase 7: Post-LB steady state for ${PHASE7_POST_LB_S}s..."

# Run one final 500 Mbps iperf measurement across all 51 UEs
log "  Running post-LB 500 Mbps iperf measurement (1 step, 30s)..."
nohup bash "$COLLECT_DIR/$IPERF_500_SCRIPT" 51 30 \
    >> "$COLLECT_DIR/iperf_postlb.log" 2>&1 &
POST_LB_PID=$!

sleep "$PHASE7_POST_LB_S"
wait "$POST_LB_PID" 2>/dev/null || true

log "Phase 7 complete."

# ══════════════════════════════════════════════════════════════
# DONE: Stop collectors + pull results + write summary
# ══════════════════════════════════════════════════════════════
set_phase "collection_complete"
log "=== Collection complete. Stopping collectors... ==="
stop_all_collectors

# ── Pull results from remote nodes ──────────────────────────
log "Pulling results from all nodes..."
mkdir -p \
    "$RESULTS_DIR/gnb1" "$RESULTS_DIR/gnb2" \
    "$RESULTS_DIR/uehost2" "$RESULTS_DIR/core"

for host_dir in \
    "$GNB1_HOST:$RESULTS_DIR/gnb1" \
    "$GNB2_HOST:$RESULTS_DIR/gnb2" \
    "$UEHOST2_HOST:$RESULTS_DIR/uehost2" \
    "$CORE_HOST:$RESULTS_DIR/core"; do
    IFS=':' read -r host destdir <<< "$host_dir"
    scp $SSH_OPTS -r "$host:$COLLECT_DIR/*.csv" "$destdir/" 2>/dev/null || true
    scp $SSH_OPTS -r "$host:$COLLECT_DIR/*.txt" "$destdir/" 2>/dev/null || true
    scp $SSH_OPTS -r "$host:$COLLECT_DIR/*.log" "$destdir/" 2>/dev/null || true
done
# Local files
cp "$COLLECT_DIR"/*.csv "$RESULTS_DIR/" 2>/dev/null || true
cp "$COLLECT_DIR"/*.txt "$RESULTS_DIR/" 2>/dev/null || true
log "Results pulled to $RESULTS_DIR"

# ── Merge handover summary from uehost2 if available ─────────
if [ ! -f "$HANDOVER_SUMMARY" ]; then
    scp $SSH_OPTS "$UEHOST2_HOST:$COLLECT_DIR/ue51_handover_summary.txt" \
        "$HANDOVER_SUMMARY" 2>/dev/null || true
fi

# ── Compute per-phase gNB load from gnb_metrics.csv ─────────
GNB_CSV="$COLLECT_DIR/gnb_metrics.csv"
scp $SSH_OPTS "$GNB1_HOST:$COLLECT_DIR/gnb_metrics.csv" \
    "$COLLECT_DIR/gnb_metrics_gnb1.csv" 2>/dev/null || true
scp $SSH_OPTS "$GNB2_HOST:$COLLECT_DIR/gnb_metrics.csv" \
    "$COLLECT_DIR/gnb_metrics_gnb2.csv" 2>/dev/null || true

# ── Write experiment summary ─────────────────────────────────
{
    echo "======================================================"
    echo "  UE51 Load-Balancing Experiment — Summary"
    echo "  $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "======================================================"
    echo ""
    echo "── Timing ────────────────────────────────────────────"
    echo "LB trigger timestamp (ms)         : $LB_TRIGGER_TS"
    echo "UE51 detach timestamp (ms)        : $DETACH_TS"
    echo "UE51 attach to gNB2 (ms)          : $ATTACH_TS"
    echo "Handover duration (detach→attach) : ${HANDOVER_DURATION_MS} ms"
    echo "E2E LB duration   (trigger→attach): ${E2E_DURATION_MS} ms"
    echo ""
    echo "── Node Roles ────────────────────────────────────────"
    echo "gNB1 (pc818 / 10.10.1.2) : source — hosted UE1-50 + UE51 pre-LB"
    echo "gNB2 (pc802 / 10.10.1.3) : target — hosts UE51 post-LB"
    echo "uehost2 (pc801 / 10.10.1.5): runs UE51 srsue process"
    echo ""
    echo "── Key Research Findings ─────────────────────────────"
    echo "1. HANDOVER_LATENCY_MS=${HANDOVER_DURATION_MS}"
    echo "   → Critical for algorithm design: target < 500 ms for transparent LB"
    echo ""
    echo "2. E2E_LB_LATENCY_MS=${E2E_DURATION_MS}"
    echo "   → Includes control-plane signalling + RRC re-establishment overhead"
    echo ""
    echo "3. CPU_POWER_DELTA_PRE_LB vs POST_LB"
    echo "   → See: gnb_metrics_gnb1.csv (sys_load col) and power_gnb1.csv"
    echo "   → Reduced load on gNB1 after LB = energy saved per UE offloaded"
    echo ""
    echo "4. GNB1_UE_COUNT_REDUCTION"
    echo "   → Phase 4 nof_ue=51  →  Phase 7 nof_ue=50"
    echo "   → Verify in gnb_metrics_gnb1.csv: filter phase=phase7_gnb2_post_lb"
    echo ""
    echo "5. GNB2_POWER_INCREASE_ON_ATTACH"
    echo "   → power_gnb2.csv: compare pkg0_power_W pre vs post UE51 arrival"
    echo "   → Marginal power cost of serving one additional UE at 500 Mbps"
    echo ""
    echo "6. THROUGHPUT_DURING_HANDOVER"
    echo "   → iperf_results_500.csv: rows with phase=phase6_handover_window"
    echo "   → Shows throughput degradation (if any) during LB transition"
    echo ""
    echo "7. SRSENB_SYS_LOAD_VS_NOF_UE"
    echo "   → gnb_metrics_gnb1.csv: correlate nof_ue with sys_load per phase"
    echo "   → Input for load-prediction model in CPU power-saving algorithm"
    echo ""
    echo "8. PER_CORE_CPU_IMBALANCE"
    echo "   → deep_sysmon_gnb1.csv: compare per-core CPU% at nof_ue=50 vs 51"
    echo "   → Identifies whether gNB adds UE on a single core (IRQ affinity)"
    echo ""
    echo "── Output Files ──────────────────────────────────────"
    echo "System metrics    : $COLLECT_DIR/system_metrics.csv (all nodes)"
    echo "gNB1 metrics      : $COLLECT_DIR/gnb_metrics_gnb1.csv"
    echo "gNB2 metrics      : $COLLECT_DIR/gnb_metrics_gnb2.csv"
    echo "RAPL power gNB1   : $COLLECT_DIR/power_gnb1.csv (via gnb1 pull)"
    echo "RAPL power gNB2   : $COLLECT_DIR/power_gnb2.csv (via gnb2 pull)"
    echo "Deep sysmon gNB1  : $COLLECT_DIR/deep_sysmon_gnb1.csv"
    echo "Deep sysmon gNB2  : $COLLECT_DIR/deep_sysmon_gnb2.csv"
    echo "iperf 500 Mbps    : $COLLECT_DIR/iperf_results_500.csv"
    echo "UE51 handover CSV : $COLLECT_DIR/ue51_handover.csv"
    echo "UE51 handover sum : $HANDOVER_SUMMARY"
    echo "Orchestrator log  : $LOG"
    echo ""
    echo "── Next Step ─────────────────────────────────────────"
    echo "python3 scripts/merge_ran_csv.py --output results/master_dataset.csv"
    echo "======================================================"
} > "$EXPERIMENT_SUMMARY"

cat "$EXPERIMENT_SUMMARY" | tee -a "$LOG"

log "=== Experiment complete ==="
log "Summary: $EXPERIMENT_SUMMARY"
log "All results: $RESULTS_DIR"

