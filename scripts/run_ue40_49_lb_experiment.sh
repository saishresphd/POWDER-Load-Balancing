#!/usr/bin/env bash
# ============================================================
# run_ue40_49_lb_experiment.sh
# 9-UE Batch Load-Balancing Experiment Orchestrator
#
# Migrates UE40-49 (10 UEs) from gNB1 to gNB2 in a single
# controlled batch. Collects all RAN, power, and CPU data needed
# to extend key findings from IEEE paper 10949489:
#   Eq.3: Ptotal = Pbase + NaU·PaU + NUi·PUi
#   Eq.4: Psaved = Pactive - Pswitched
#   KF-3: CPU power savings from UE disconnection
#   KF-4: Marginal power cost of UE migration onto target gNB
#
# UE40-49 run on uehost1 (pc808 / 10.10.1.4).
# gNB2 LB-target enb slots: configs/gnb2/enb_ue40..49.conf
# UE gnb2 configs: configs/ues/ue40_gnb2.conf .. ue49_gnb2.conf
#
# Phases:
#   Phase 1  (60s)  Baseline: 50 UEs on gNB1, iperf ramp active
#   Phase 2         Ramp UE40-49 to 500 Mbps (peak load before LB)
#   Phase 3  (60s)  Hold 500 Mbps peak — pre-LB steady state
#   Phase 4         Trigger LB: detach UE40-49 from gNB1 sequentially
#   Phase 5         Handover window: start gNB2 slots + reconnect UEs
#   Phase 6  (90s)  Post-LB steady state: gNB1 has 40 UEs, gNB2 has 9
#   Done            Stop collectors, pull results, write summary
#
# Run on: uehost1 (pc808)
# Usage : bash run_ue40_49_lb_experiment.sh
# ============================================================
set -euo pipefail

# ── Node addresses ──────────────────────────────────────────
CORE_HOST="saish@10.10.1.1"
GNB1_HOST="saish@10.10.1.2"
GNB2_HOST="saish@10.10.1.3"
GNB1_IP="10.10.1.2"
GNB2_IP="10.10.1.3"

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

# ── UE range for this experiment ────────────────────────────
UE_START=40
UE_END=49
UE_COUNT=$(( UE_END - UE_START + 1 ))      # = 10 (UE40 kept as anchor, 9 migrated = 40-49)
# NOTE: UE40 is included in the detach sweep but per-paper the "9 UEs"
#       are 41-49; UE40 serves as a control (can be skipped via SKIP_UE40=true).
SKIP_UE40="${SKIP_UE40:-false}"             # set to true to keep UE40 on gNB1

# ── Timing (seconds) ────────────────────────────────────────
PHASE1_BASELINE_S=60
PHASE3_HOLD_S=60
PHASE6_POST_LB_S=90
DETACH_GAP_S=3          # gap between each UE detach (staggered to observe per-UE power drop)
ATTACH_GAP_S=2          # gap between each UE re-attach to gNB2
ATTACH_WAIT_S=30        # max wait per UE for tun to come UP on gNB2

# ── Paths ───────────────────────────────────────────────────
COLLECT_DIR="/tmp/ran_collect"
SCRIPTS_DIR="$COLLECT_DIR/scripts"
CONFIGS_DIR="$COLLECT_DIR/configs"
LOG="$COLLECT_DIR/lb9ue_orchestrator.log"
PHASE_FILE="$COLLECT_DIR/phase.txt"
RESULTS_DIR="$COLLECT_DIR/results"
TRIGGER_FILE="$COLLECT_DIR/lb_trigger_9ue.txt"
SUMMARY_FILE="$COLLECT_DIR/lb9ue_experiment_summary.txt"

mkdir -p "$COLLECT_DIR" "$RESULTS_DIR"
log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" | tee -a "$LOG"; }
die() { log "FATAL: $*"; exit 1; }

# ── Phase broadcaster ────────────────────────────────────────
set_phase() {
    local phase="$1"
    echo "$phase" > "$PHASE_FILE"
    for host in "$GNB1_HOST" "$GNB2_HOST" "$CORE_HOST"; do
        ssh $SSH_OPTS "$host" "mkdir -p $COLLECT_DIR; echo '$phase' > $PHASE_FILE" 2>/dev/null &
    done
    wait
    log "━━━ Phase → $phase ━━━"
}

# ── Stop all collectors on all nodes ────────────────────────
stop_all_collectors() {
    log "Stopping all collectors..."
    for host in "$GNB1_HOST" "$GNB2_HOST" "$CORE_HOST"; do
        ssh $SSH_OPTS "$host" \
            "pkill -f collect_system_metrics || true
             pkill -f collect_gnb_metrics    || true
             pkill -f collect_rich_gnb       || true
             pkill -f collect_power          || true
             pkill -f deep_sysmon            || true
             pkill -f collect_perf_ipc       || true" \
            2>/dev/null || true
    done
    pkill -f collect_system_metrics 2>/dev/null || true
    pkill -f collect_ue40_49_handover 2>/dev/null || true
    pkill -f run_iperf 2>/dev/null || true
    log "Collectors stopped."
}
trap stop_all_collectors EXIT

# ── Wait for UE tun device to come UP ───────────────────────
wait_for_tun() {
    local ue_id="$1" max_s="$2"
    local tun_name="tun_srsue${ue_id}"
    for i in $(seq 1 "$max_s"); do
        sleep 1
        if ip netns exec ue${ue_id} ip link show "$tun_name" 2>/dev/null | grep -q "UP"; then
            return 0
        fi
    done
    return 1
}

# ── Check UE tun is DOWN (detached) ─────────────────────────
check_tun_down() {
    local ue_id="$1"
    local tun_name="tun_srsue${ue_id}"
    ! ip netns exec ue${ue_id} ip link show "$tun_name" 2>/dev/null | grep -q "UP"
}

TOTAL_DURATION_S=$(( PHASE1_BASELINE_S + 60 + PHASE3_HOLD_S + \
                     UE_COUNT * DETACH_GAP_S + 30 + \
                     UE_COUNT * (ATTACH_WAIT_S + ATTACH_GAP_S) + \
                     PHASE6_POST_LB_S + 120 ))

log "==================================================================="
log "  9-UE Load-Balancing Experiment (UE${UE_START}-${UE_END} → gNB2)"
log "  gNB1=${GNB1_HOST}  gNB2=${GNB2_HOST}  Core=${CORE_HOST}"
log "  Total estimated duration: ${TOTAL_DURATION_S}s"
log "==================================================================="

# ══════════════════════════════════════════════════════════════
# STEP 0: Stage scripts + configs to remote nodes
# ══════════════════════════════════════════════════════════════
log "--- Staging scripts and configs to remote nodes ---"

for host in "$GNB1_HOST" "$GNB2_HOST" "$CORE_HOST"; do
    ssh $SSH_OPTS "$host" "mkdir -p $SCRIPTS_DIR $CONFIGS_DIR $COLLECT_DIR" &
done
wait

# Push collector scripts to gNB1 and gNB2
for f in \
    "$COLLECT_DIR/collect_system_metrics.sh" \
    "$COLLECT_DIR/collect_gnb_metrics.sh" \
    "$COLLECT_DIR/collect_rich_gnb.sh" \
    "$COLLECT_DIR/collect_power.sh" \
    "$COLLECT_DIR/deep_sysmon.py" \
    "$COLLECT_DIR/collect_perf_ipc.sh"; do
    [ -f "$f" ] || continue
    for host in "$GNB1_HOST" "$GNB2_HOST"; do
        scp $SSH_OPTS "$f" "$host:$COLLECT_DIR/" 2>/dev/null &
    done
done
wait

# Push gnb2 target configs for UE40-49 to gNB2
log "  Pushing gnb2 enb_ue40..49 configs to gNB2..."
for i in $(seq $UE_START $UE_END); do
    CONF="${CONFIGS_DIR}/gnb2/enb_ue${i}.conf"
    [ -f "$CONF" ] && scp $SSH_OPTS "$CONF" "$GNB2_HOST:/etc/srsenb/enb_ue${i}.conf" 2>/dev/null || \
    log "  WARN: $CONF not found — must be pre-installed on gNB2"
done

log "Staging complete."

# ══════════════════════════════════════════════════════════════
# START ALL COLLECTORS (run throughout every phase)
# ══════════════════════════════════════════════════════════════
log "--- Starting background collectors on gNB1, gNB2, Core ---"

# System metrics (5s interval) on all nodes
for host in "$GNB1_HOST" "$GNB2_HOST" "$CORE_HOST"; do
    ssh $SSH_OPTS "$host" \
        "nohup bash $COLLECT_DIR/collect_system_metrics.sh 5 $TOTAL_DURATION_S \
         >> $COLLECT_DIR/sysmet.log 2>&1 &
         echo \$! > $COLLECT_DIR/sysmet.pid" 2>/dev/null || true
done
nohup bash "$COLLECT_DIR/collect_system_metrics.sh" 5 "$TOTAL_DURATION_S" \
    >> "$COLLECT_DIR/sysmet_uehost1.log" 2>&1 &
SYSMET_PID=$!

# gNB metrics (5s interval) — gNB1: UE1-50, gNB2: UE40-49 target slots
ssh $SSH_OPTS "$GNB1_HOST" \
    "nohup bash $COLLECT_DIR/collect_gnb_metrics.sh 5 $TOTAL_DURATION_S gnb1 1 50 \
     >> $COLLECT_DIR/gnbmet_gnb1.log 2>&1 &
     echo \$! > $COLLECT_DIR/gnbmet_gnb1.pid" 2>/dev/null || true

ssh $SSH_OPTS "$GNB2_HOST" \
    "nohup bash $COLLECT_DIR/collect_gnb_metrics.sh 5 $TOTAL_DURATION_S gnb2 40 49 \
     >> $COLLECT_DIR/gnbmet_gnb2.log 2>&1 &
     echo \$! > $COLLECT_DIR/gnbmet_gnb2.pid" 2>/dev/null || true

# RAPL power (1s) on gNB1 + gNB2
ssh $SSH_OPTS "$GNB1_HOST" \
    "nohup sudo bash $COLLECT_DIR/collect_power.sh $TOTAL_DURATION_S 1 $COLLECT_DIR/power_gnb1.csv \
     >> $COLLECT_DIR/power_gnb1.log 2>&1 &
     echo \$! > $COLLECT_DIR/power_gnb1.pid" 2>/dev/null || \
    log "WARN: RAPL power collector failed on gNB1 (may need sudo)"

ssh $SSH_OPTS "$GNB2_HOST" \
    "nohup sudo bash $COLLECT_DIR/collect_power.sh $TOTAL_DURATION_S 1 $COLLECT_DIR/power_gnb2.csv \
     >> $COLLECT_DIR/power_gnb2.log 2>&1 &
     echo \$! > $COLLECT_DIR/power_gnb2.pid" 2>/dev/null || \
    log "WARN: RAPL power collector failed on gNB2 (may need sudo)"

# Deep sysmon (2s) on gNB1 + gNB2
if ssh $SSH_OPTS "$GNB1_HOST" "test -f $COLLECT_DIR/deep_sysmon.py" 2>/dev/null; then
    ssh $SSH_OPTS "$GNB1_HOST" \
        "nohup python3 $COLLECT_DIR/deep_sysmon.py $TOTAL_DURATION_S 2 srsenb $COLLECT_DIR/deep_sysmon_gnb1.csv \
         >> $COLLECT_DIR/deep_sysmon_gnb1.log 2>&1 &
         echo \$! > $COLLECT_DIR/deep_sysmon_gnb1.pid" 2>/dev/null || true
    ssh $SSH_OPTS "$GNB2_HOST" \
        "nohup python3 $COLLECT_DIR/deep_sysmon.py $TOTAL_DURATION_S 2 srsenb $COLLECT_DIR/deep_sysmon_gnb2.csv \
         >> $COLLECT_DIR/deep_sysmon_gnb2.log 2>&1 &
         echo \$! > $COLLECT_DIR/deep_sysmon_gnb2.pid" 2>/dev/null || true
fi

# perf IPC collector (5s) on gNB1 + gNB2
if ssh $SSH_OPTS "$GNB1_HOST" "test -f $COLLECT_DIR/collect_perf_ipc.sh" 2>/dev/null; then
    ssh $SSH_OPTS "$GNB1_HOST" \
        "nohup bash $COLLECT_DIR/collect_perf_ipc.sh gnb1 5 \
         >> $COLLECT_DIR/perfipc_gnb1.log 2>&1 &
         echo \$! > $COLLECT_DIR/perfipc_gnb1.pid" 2>/dev/null || true
    ssh $SSH_OPTS "$GNB2_HOST" \
        "nohup bash $COLLECT_DIR/collect_perf_ipc.sh gnb2 5 \
         >> $COLLECT_DIR/perfipc_gnb2.log 2>&1 &
         echo \$! > $COLLECT_DIR/perfipc_gnb2.pid" 2>/dev/null || true
fi

# Start the multi-UE handover monitor locally on uehost1
HANDOVER_TOTAL_S=$(( UE_COUNT * (DETACH_GAP_S + ATTACH_WAIT_S + ATTACH_GAP_S) + PHASE6_POST_LB_S + 120 ))
nohup bash "$COLLECT_DIR/collect_ue40_49_handover.sh" 500 "$HANDOVER_TOTAL_S" \
    >> "$COLLECT_DIR/handover_9ue.log" 2>&1 &
HANDOVER_PID=$!

log "All collectors started. Warming up 5s..."
sleep 5

# ══════════════════════════════════════════════════════════════
# PHASE 1: Baseline — 50 UEs on gNB1, steady iperf traffic
# ══════════════════════════════════════════════════════════════
set_phase "phase1_gnb1_baseline_50ue"
log "Phase 1: Verifying 50 UEs on gNB1, running baseline iperf..."

ATTACHED=$(ssh $SSH_OPTS "$GNB1_HOST" \
    "tail -1 $COLLECT_DIR/gnb_metrics_raw_gnb1.csv 2>/dev/null | cut -d';' -f2 || echo 0" \
    2>/dev/null || echo "0")
log "  gNB1 current nof_ue = ${ATTACHED}"

# Baseline iperf: UE1-50 ramp up to 20 Mbps
if [ -f "$COLLECT_DIR/run_iperf_ramp.sh" ]; then
    bash "$COLLECT_DIR/run_iperf_ramp.sh" 50 2>&1 | tee -a "$LOG" || true
else
    log "  WARN: run_iperf_ramp.sh not found — running manual iperf for UE1-10"
    for i in $(seq 1 10); do
        ip netns exec ue${i} iperf3 -c 10.10.1.1 -u -b 20M -t 5 -J \
            > "$COLLECT_DIR/iperf_baseline_ue${i}.json" 2>/dev/null &
    done
    wait
fi
log "Phase 1: Holding baseline for ${PHASE1_BASELINE_S}s..."
sleep "$PHASE1_BASELINE_S"
log "Phase 1 baseline complete."

# ══════════════════════════════════════════════════════════════
# PHASE 2: Ramp UE40-49 to 500 Mbps (pre-LB peak load)
# ══════════════════════════════════════════════════════════════
set_phase "phase2_ramp_500mbps_prelb"
log "Phase 2: Ramping UE40-49 to 500 Mbps (pre-LB peak load)..."

for i in $(seq $UE_START $UE_END); do
    ip netns exec ue${i} iperf3 -c 10.10.1.1 -u -b 500M -t $(( PHASE3_HOLD_S + 30 )) \
        -J > "$COLLECT_DIR/iperf_prelb_ue${i}.json" 2>/dev/null &
done
log "  iperf 500 Mbps launched for UE${UE_START}-${UE_END}"

# Also keep UE1-39 at 20 Mbps for realistic background load
for i in $(seq 1 39); do
    netns="ue${i}"
    ip netns list 2>/dev/null | grep -qw "$netns" || continue
    ip netns exec "$netns" iperf3 -c 10.10.1.1 -u -b 20M -t $(( PHASE3_HOLD_S + 30 )) \
        -J > "$COLLECT_DIR/iperf_bg_ue${i}.json" 2>/dev/null &
done

log "Phase 2 ramp complete."

# ══════════════════════════════════════════════════════════════
# PHASE 3: Hold 500 Mbps — pre-LB steady state (power baseline)
# ══════════════════════════════════════════════════════════════
set_phase "phase3_hold_500mbps_prelb"
log "Phase 3: Holding 500 Mbps pre-LB steady state for ${PHASE3_HOLD_S}s..."
log "  This window establishes Pactive for Eq.4 power savings calculation."
sleep "$PHASE3_HOLD_S"
log "Phase 3 pre-LB hold complete."

# ══════════════════════════════════════════════════════════════
# PHASE 4: Trigger load-balance — detach UE40-49 from gNB1
# ══════════════════════════════════════════════════════════════
set_phase "phase4_lb_trigger_detach"
LB_TRIGGER_TS=$(date '+%s%3N')
log "Phase 4: LB trigger at ${LB_TRIGGER_TS}ms — staggered detach UE${UE_START}-${UE_END}..."

echo "lb_trigger_ts_ms=${LB_TRIGGER_TS}" > "$TRIGGER_FILE"
ssh $SSH_OPTS "$GNB1_HOST" \
    "echo 'lb_trigger_ts_ms=${LB_TRIGGER_TS}' > $COLLECT_DIR/lb_trigger_9ue.txt" 2>/dev/null || true

declare -A DETACH_TS_MAP

UE_TO_DETACH_LIST=""
for i in $(seq $UE_START $UE_END); do
    if $SKIP_UE40 && (( i == 40 )); then
        log "  Skipping UE40 (SKIP_UE40=true — used as baseline control)"
        continue
    fi
    UE_TO_DETACH_LIST="${UE_TO_DETACH_LIST} ${i}"
done

for i in $UE_TO_DETACH_LIST; do
    log "  Detaching UE${i} from gNB1..."

    # Stop srsue process for this UE (it runs in local netns ue${i})
    pkill -SIGTERM -f "srsue.*ue${i}\.conf" 2>/dev/null || \
    pkill -SIGTERM -f "srsue.*ue${i}[^0-9]" 2>/dev/null || true

    # Also stop any iperf for this UE
    ip netns exec ue${i} pkill -f iperf3 2>/dev/null || true

    DETACH_TS_MAP[$i]=$(date '+%s%3N')
    log "  UE${i} detach sent at ${DETACH_TS_MAP[$i]}ms"

    sleep "$DETACH_GAP_S"
done

log "Phase 4 complete — all UEs detach signals sent."

# ══════════════════════════════════════════════════════════════
# PHASE 5: Handover window — start gNB2 LB slots + reconnect UEs
# ══════════════════════════════════════════════════════════════
set_phase "phase5_handover_window"
log "Phase 5: Starting gNB2 LB target slots and reconnecting UEs..."

# Ensure gnb2 IP aliases for UE40-49 are present (10.10.1.240-249)
log "  Adding IP aliases 10.10.1.240-249 on gNB2..."
ssh $SSH_OPTS "$GNB2_HOST" "
  DEV=\$(ip route | grep '^default' | awk '{print \$5}' | head -1)
  [ -z \"\$DEV\" ] && DEV=enp6s0f3
  for j in \$(seq 240 249); do
    ip=\"10.10.1.\${j}\"
    if ! ip addr show dev \$DEV 2>/dev/null | grep -q \"\${ip}/\"; then
      sudo ip addr add \${ip}/24 dev \$DEV 2>/dev/null && echo \"Added \${ip}\" || true
    fi
  done
" 2>/dev/null || log "WARN: Could not add gnb2 IP aliases"

# Brief stabilisation pause
sleep 2

# Start gNB2 srsenb slots for UE40-49 + reconnect each UE
declare -A ATTACH_TS_MAP
declare -A HANDOVER_MS_MAP

for i in $UE_TO_DETACH_LIST; do
    log "  Starting gNB2 slot + reconnecting UE${i}..."

    # Start the gNB2 enb slot on pc802
    ssh $SSH_OPTS "$GNB2_HOST" "
      mkdir -p /tmp/gnb2_logs
      if ! ps aux | grep -q '[s]rsenb.*enb_ue${i}'; then
        sudo srsenb /etc/srsenb/enb_ue${i}.conf \
          >> /tmp/gnb2_logs/ue${i}_stdout.log 2>&1 &
        echo \"Started gnb2 slot enb_ue${i}\"
      else
        echo \"gnb2 slot enb_ue${i} already running\"
      fi
      sleep 1
    " 2>/dev/null || log "WARN: Could not start gnb2 enb slot for UE${i}"

    sleep 1

    # Tear down old netns and re-create to get clean ZMQ socket state
    ip netns del ue${i} 2>/dev/null || true
    ip netns add ue${i} 2>/dev/null || true

    # Stage the gnb2 UE config locally
    UE_GNB2_CONF="$CONFIGS_DIR/ues/ue${i}_gnb2.conf"
    if [ ! -f "$UE_GNB2_CONF" ]; then
        # Fall back to pre-installed location
        UE_GNB2_CONF="/etc/srsue/ue${i}_gnb2.conf"
    fi
    [ -f "$UE_GNB2_CONF" ] || die "UE${i} gnb2 config not found: $UE_GNB2_CONF"

    # Launch srsue pointing at gNB2
    nohup srsue "$UE_GNB2_CONF" \
        --log.filename="$COLLECT_DIR/ue${i}_gnb2.log" \
        >> "$COLLECT_DIR/ue${i}_gnb2_stdout.log" 2>&1 </dev/null &

    log "  UE${i} srsue started → gNB2. Waiting for attach (max ${ATTACH_WAIT_S}s)..."
    if wait_for_tun "$i" "$ATTACH_WAIT_S"; then
        ATTACH_TS_MAP[$i]=$(date '+%s%3N')
        HANDOVER_MS_MAP[$i]=$(( ${ATTACH_TS_MAP[$i]} - ${DETACH_TS_MAP[$i]:-${LB_TRIGGER_TS}} ))
        log "  *** UE${i} ATTACHED to gNB2 — HO duration=${HANDOVER_MS_MAP[$i]}ms ***"
    else
        ATTACH_TS_MAP[$i]="TIMEOUT"
        HANDOVER_MS_MAP[$i]="TIMEOUT"
        log "  WARNING: UE${i} did not attach within ${ATTACH_WAIT_S}s"
    fi

    sleep "$ATTACH_GAP_S"
done

log "Phase 5 handover window complete."

# ══════════════════════════════════════════════════════════════
# PHASE 6: Post-LB steady state
# gNB1: 40 UEs remaining  |  gNB2: 9 migrated UEs active
# This window captures Pswitched (Eq.4) and post-LB power model
# ══════════════════════════════════════════════════════════════
set_phase "phase6_post_lb_steady_state"
log "Phase 6: Post-LB steady state for ${PHASE6_POST_LB_S}s..."
log "  gNB1 target: 40 UEs  |  gNB2 target: 9 migrated UEs"
log "  Power measurements here → Pswitched in Eq.4: Psaved = Pactive - Pswitched"

# Run post-LB iperf on migrated UEs (now on gNB2)
for i in $UE_TO_DETACH_LIST; do
    [ "${ATTACH_TS_MAP[$i]:-TIMEOUT}" = "TIMEOUT" ] && continue
    ip netns exec ue${i} iperf3 -c 10.10.1.1 -u -b 500M -t "$PHASE6_POST_LB_S" \
        -J > "$COLLECT_DIR/iperf_postlb_ue${i}.json" 2>/dev/null &
done
log "  Post-LB iperf started for successfully migrated UEs."

sleep "$PHASE6_POST_LB_S"
log "Phase 6 complete."

# ══════════════════════════════════════════════════════════════
# DONE — Stop collectors, pull results, write summary
# ══════════════════════════════════════════════════════════════
set_phase "collection_complete"
log "=== Collection complete. Stopping collectors... ==="
stop_all_collectors
sleep 3   # flush final writes

# ── Pull results from remote nodes ──────────────────────────
log "Pulling results from gNB1, gNB2, Core..."
mkdir -p "$RESULTS_DIR"/{gnb1,gnb2,core}

for host_label in "gnb1:$GNB1_HOST" "gnb2:$GNB2_HOST" "core:$CORE_HOST"; do
    label="${host_label%%:*}"
    host="${host_label##*:}"
    scp $SSH_OPTS -r "$host:$COLLECT_DIR/*.csv" "$RESULTS_DIR/$label/" 2>/dev/null || true
    scp $SSH_OPTS -r "$host:$COLLECT_DIR/*.txt" "$RESULTS_DIR/$label/" 2>/dev/null || true
    scp $SSH_OPTS -r "$host:$COLLECT_DIR/*.log" "$RESULTS_DIR/$label/" 2>/dev/null || true
done
cp "$COLLECT_DIR"/*.csv "$RESULTS_DIR/" 2>/dev/null || true
cp "$COLLECT_DIR"/*.json "$RESULTS_DIR/" 2>/dev/null || true
log "Results pulled to $RESULTS_DIR"

# ── Compute E2E LB duration ──────────────────────────────────
LAST_ATTACH_TS=0
for i in $UE_TO_DETACH_LIST; do
    ts="${ATTACH_TS_MAP[$i]:-0}"
    [[ "$ts" =~ ^[0-9]+$ ]] && (( ts > LAST_ATTACH_TS )) && LAST_ATTACH_TS=$ts
done
E2E_LB_MS=$(( LAST_ATTACH_TS > 0 ? LAST_ATTACH_TS - LB_TRIGGER_TS : -1 ))

# ── Write experiment summary ─────────────────────────────────
{
    echo "=============================================================="
    echo "  9-UE Load-Balancing Experiment (UE${UE_START}-${UE_END})"
    echo "  $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "=============================================================="
    echo ""
    echo "── Timing ───────────────────────────────────────────────────"
    echo "LB trigger timestamp (ms)         : $LB_TRIGGER_TS"
    echo "Last UE attach to gNB2 (ms)       : $LAST_ATTACH_TS"
    echo "E2E LB duration (trigger→all-done): ${E2E_LB_MS} ms"
    echo ""
    echo "── Per-UE Handover Latencies ────────────────────────────────"
    total_ho=0; n_ho=0
    for i in $UE_TO_DETACH_LIST; do
        ho="${HANDOVER_MS_MAP[$i]:-N/A}"
        detach="${DETACH_TS_MAP[$i]:-N/A}"
        attach="${ATTACH_TS_MAP[$i]:-N/A}"
        echo "  UE${i}: detach=${detach}ms  attach=${attach}ms  HO_ms=${ho}"
        [[ "$ho" =~ ^[0-9]+$ ]] && total_ho=$(( total_ho + ho )) && (( n_ho++ ))
    done
    if (( n_ho > 0 )); then
        avg_ho=$(python3 -c "print(f'{$total_ho / $n_ho:.1f}')")
        echo ""
        echo "Average HO latency (successful)   : ${avg_ho} ms"
        echo "Successful handovers              : ${n_ho} / ${UE_COUNT}"
    fi
    echo ""
    echo "── Node Roles ───────────────────────────────────────────────"
    echo "gNB1 (pc818 / 10.10.1.2) : source — 50 UEs → reduced to 40 post-LB"
    echo "gNB2 (pc802 / 10.10.1.3) : target — receives UE${UE_START}-${UE_END}"
    echo "uehost1 (pc808 / 10.10.1.4): runs UE40-49 srsue processes"
    echo ""
    echo "── Paper Equations Applied (IEEE 10949489) ──────────────────"
    echo ""
    echo "Eq.2: Power-law model — P(load) = α · load^β + γ"
    echo "  → Fit using power_gnb1.csv vs gnb_metrics.csv sys_load"
    echo "  → Pre-LB  : gNB1 with 50 UEs (phase3_hold_500mbps_prelb)"
    echo "  → Post-LB : gNB1 with 40 UEs (phase6_post_lb_steady_state)"
    echo ""
    echo "Eq.3: Ptotal = Pbase + NaU·PaU + NUi·PUi"
    echo "  → Pre-LB  gNB1: NaU=50, measure Ptotal from power_gnb1.csv"
    echo "  → Post-LB gNB1: NaU=40, measure Ptotal (= Pswitched)"
    echo "  → gNB2 receives: NaU increases by 9, measure marginal PaU"
    echo ""
    echo "Eq.4: Psaved = Pactive - Pswitched"
    echo "  → Pactive  = power_gnb1 during phase3 (50 UEs, 500 Mbps)"
    echo "  → Pswitched = power_gnb1 during phase6 (40 UEs)"
    echo "  → Net savings = Psaved(gNB1) - ΔPcost(gNB2)"
    echo ""
    echo "Key Finding 3 (extended):"
    echo "  → UE40-49 disconnected → gNB1 CPU power savings observed"
    echo "  → Compare sys_load in gnb_metrics_gnb1.csv phase3 vs phase6"
    echo ""
    echo "Key Finding 4 (extended with 9 UEs):"
    echo "  → gNB2 marginal power: power_gnb2.csv pre-LB vs post-LB"
    echo "  → Per-UE marginal cost PaU = ΔP_gnb2 / 9"
    echo ""
    echo "── Data Files for Analysis ──────────────────────────────────"
    echo "power_gnb1.csv        : RAPL pkg0 W (1s) — source gNB"
    echo "power_gnb2.csv        : RAPL pkg0 W (1s) — target gNB"
    echo "gnb_metrics_gnb1.csv  : nof_ue, sys_load, dl/ul brate per phase"
    echo "gnb_metrics_gnb2.csv  : nof_ue, sys_load on gNB2 after migration"
    echo "system_metrics.csv    : cpu_pct, ipc, ctxt_rate per node"
    echo "deep_sysmon_gnb1.csv  : per-core CPU%, per-process metrics"
    echo "deep_sysmon_gnb2.csv  : per-core CPU% after UE arrival"
    echo "perf_ipc_gnb1.csv     : IPC, cache-miss rate vs load"
    echo "ue40_49_handover.csv  : per-UE tun state timeline"
    echo "ue40_49_handover_summary.txt : per-UE HO latency table"
    echo "iperf_prelb_ueN.json  : throughput pre-LB (Mbps per UE)"
    echo "iperf_postlb_ueN.json : throughput post-LB on gNB2"
    echo ""
    echo "── Next Step ─────────────────────────────────────────────────"
    echo "python3 scripts/analyze_lb_results.py \\"
    echo "  --results-dir $RESULTS_DIR --plots"
    echo "=============================================================="
} > "$SUMMARY_FILE"

cat "$SUMMARY_FILE" | tee -a "$LOG"
log "=== 9-UE LB Experiment complete ==="
log "Summary : $SUMMARY_FILE"
log "Results : $RESULTS_DIR"
