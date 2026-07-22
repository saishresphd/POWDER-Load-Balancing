#!/bin/bash
# ============================================================
# orchestrate_collection.sh  — run on uehost1 (pc808)
# Master orchestrator that:
#   Phase 1: UE1-50 on gNB1 — collect data + iperf ramp
#   Phase 2: Start UE51-100 on gNB1 first (LB candidates)
#   Phase 3: Load-balance UE51-100 to gNB2 — collect transition data
#   Phase 4: Steady state on gNB2 — collect final data
#
# Parallel: system_metrics.sh runs continuously in background
#           gnb_metrics.sh runs on gnb1/gnb2 (started remotely)
# ============================================================
set -euo pipefail

COLLECT_DIR=/tmp/ran_collect
mkdir -p "$COLLECT_DIR"
LOG="$COLLECT_DIR/orchestrator.log"
IPERF_SERVER="10.45.0.1"
GNB1="saish@pc818.emulab.net"
GNB2="saish@pc802.emulab.net"
UEHOST2="saish@pc801.emulab.net"
CORE="saish@pc811.emulab.net"

log() { echo "[$(date -u +%H:%M:%SZ)] $*" | tee -a "$LOG"; }

set_phase() {
    echo "$1" > "$COLLECT_DIR/phase.txt"
    ssh -o StrictHostKeyChecking=no $GNB1 "echo '$1' > /tmp/ran_collect/phase.txt" 2>/dev/null &
    ssh -o StrictHostKeyChecking=no $GNB2 "echo '$1' > /tmp/ran_collect/phase.txt" 2>/dev/null &
    ssh -o StrictHostKeyChecking=no $UEHOST2 "echo '$1' > /tmp/ran_collect/phase.txt" 2>/dev/null &
    wait
    log "Phase → $1"
}

log "=== Orchestrator started ==="

# ── Start system metrics collection on ALL nodes ────────────────
log "Starting system metrics collectors on all nodes..."
for HOST in $GNB1 $GNB2 $UEHOST2 $CORE; do
    ssh -o StrictHostKeyChecking=no -f $HOST \
      "mkdir -p /tmp/ran_collect; nohup bash /tmp/ran_collect/collect_system_metrics.sh 5 7200 >> /tmp/ran_collect/sysmetrics.log 2>&1 &"
done
nohup bash "$COLLECT_DIR/collect_system_metrics.sh" 5 7200 >> "$COLLECT_DIR/sysmetrics_uehost1.log" 2>&1 &
log "System metrics collectors started"

# ── Start gNB metrics collection ────────────────────────────────
log "Starting gNB metrics collectors..."
ssh -o StrictHostKeyChecking=no -f $GNB1 \
  "nohup bash /tmp/ran_collect/collect_gnb_metrics.sh 5 7200 gnb1 1 50 >> /tmp/ran_collect/gnb1_collect.log 2>&1 &"
ssh -o StrictHostKeyChecking=no -f $GNB2 \
  "nohup bash /tmp/ran_collect/collect_gnb_metrics.sh 5 7200 gnb2 51 100 >> /tmp/ran_collect/gnb2_collect.log 2>&1 &"
log "gNB metrics collectors started"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# PHASE 1: UE1-50 baseline on gNB1
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
set_phase "phase1_gnb1_baseline"
log "Phase 1: Verifying UE1-50 attached on gNB1..."

ATTACHED=$(bash /tmp/check_all_ues.sh 1 50 2>/dev/null | grep -c "ATTACHED" || echo 0)
log "  UE1-50 attached: $ATTACHED/50"

log "Phase 1: Running iperf ramp on UE1-50..."
bash /tmp/ran_collect/run_iperf_ramp.sh 1 50 $IPERF_SERVER
log "Phase 1: iperf ramp complete"

# Collect 60s steady-state baseline
log "Phase 1: Collecting 60s steady-state baseline..."
sleep 60

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# PHASE 2: Add LB candidates UE51-60 to gNB1 first
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
set_phase "phase2_lb_candidates_on_gnb1"
log "Phase 2: Starting UE51-100 on uehost2 (connecting to gNB2)..."

ssh -o StrictHostKeyChecking=no $UEHOST2 \
  "bash /tmp/start_ues_51_100.sh 51 100 25" 2>&1 | tee -a "$LOG" &

log "Phase 2: Waiting for UE51-100 attach (parallel)..."
sleep 30

ATTACHED2=$(ssh -o StrictHostKeyChecking=no $UEHOST2 \
  "bash /tmp/check_all_ues.sh 51 100 2>/dev/null | grep -c ATTACHED || echo 0" 2>/dev/null || echo 0)
log "  UE51-100 attached: $ATTACHED2/50"

# iperf on the newly attached UEs
log "Phase 2: Running iperf on UE51-100..."
ssh -o StrictHostKeyChecking=no $UEHOST2 \
  "bash /tmp/ran_collect/run_iperf_ramp.sh 51 100 $IPERF_SERVER" 2>&1 | tee -a "$LOG" &

# simultaneous iperf on UE1-50 to stress gNB1
bash /tmp/ran_collect/run_iperf_ramp.sh 1 50 $IPERF_SERVER &
wait
log "Phase 2: combined iperf done"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# PHASE 3: Monitor and steady-state on gNB2
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
set_phase "phase3_steady_state_gnb2"
log "Phase 3: Collecting 120s steady-state with all 100 UEs..."

# Final iperf ramp on all 100 UEs simultaneously
log "Phase 3: Final iperf ramp all 100 UEs..."
bash /tmp/ran_collect/run_iperf_ramp.sh 1 50 $IPERF_SERVER &
ssh -o StrictHostKeyChecking=no $UEHOST2 \
  "bash /tmp/ran_collect/run_iperf_ramp.sh 51 100 $IPERF_SERVER" &
wait

sleep 60
set_phase "collection_complete"
log "=== Data collection complete ==="
log "Results in $COLLECT_DIR on each node"
log "Run: python3 scripts/merge_ran_csv.py --output results/master_dataset.csv"
