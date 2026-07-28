#!/bin/bash
# =============================================================================
# master_lb_experiment.sh  — Full UE51 load-balancing experiment orchestrator
# Branch: 110-ue-scale
# Nodes:  gnb1=pc818  gnb2=pc802  core=pc811  uehost1=pc808  uehost2=pc801
# Run on: uehost1 (pc808)  ssh saish@pc808.emulab.net
# =============================================================================
set -euo pipefail

REPO_DIR="${REPO_DIR:-$HOME/POWDER-Load-Balancing}"
LOG_DIR="/tmp/ran_collect"
RESULTS_DIR="$LOG_DIR/results"
PHASE_FILE="$LOG_DIR/phase.txt"

GNB1="saish@pc818.emulab.net"
GNB2="saish@pc802.emulab.net"
CORE="saish@pc811.emulab.net"
UEHOST1="saish@pc808.emulab.net"
UEHOST2="saish@pc801.emulab.net"
SSH="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10"

mkdir -p "$LOG_DIR" "$RESULTS_DIR"
exec > >(tee -a "$LOG_DIR/master_experiment.log") 2>&1

log() { echo "[$(date '+%H:%M:%S')] $*"; }
phase() {
  echo "$1" > "$PHASE_FILE"
  for node in "$GNB1" "$GNB2" "$CORE" "$UEHOST1" "$UEHOST2"; do
    $SSH "$node" "mkdir -p /tmp/ran_collect && echo '$1' > /tmp/ran_collect/phase.txt" 2>/dev/null || true
  done
  log "=== PHASE: $1 ==="
}

# ---------------------------------------------------------------------------
# PHASE 0: Pre-flight checks
# ---------------------------------------------------------------------------
phase "PRE_FLIGHT"
log "Checking 50 UEs on gnb1..."
UE_COUNT=$($SSH "$GNB1" "ps aux | grep -c '[s]rsue'" 2>/dev/null || echo 0)
log "UEs detected on gnb1: $UE_COUNT"

log "Pulling latest scripts on all nodes..."
for node in "$GNB1" "$GNB2" "$CORE" "$UEHOST1" "$UEHOST2"; do
  $SSH "$node" "cd $REPO_DIR && git fetch origin 110-ue-scale && git checkout 110-ue-scale && git pull" 2>/dev/null || true
  $SSH "$node" "chmod +x $REPO_DIR/scripts/*.sh" 2>/dev/null || true
done

# ---------------------------------------------------------------------------
# PHASE 1: Start collectors on all nodes (pre-LB baseline)
# ---------------------------------------------------------------------------
phase "BASELINE_COLLECTION"
log "Starting deep system monitors on gnb1, gnb2, core..."

$SSH "$GNB1" "cd $REPO_DIR && nohup bash scripts/launch_gnb1_collectors.sh > /tmp/ran_collect/gnb1_collectors.log 2>&1 &"
$SSH "$GNB2" "mkdir -p /tmp/ran_collect && nohup bash $REPO_DIR/scripts/collect_system_metrics.sh gnb2 > /tmp/ran_collect/system_metrics_gnb2.log 2>&1 &"
$SSH "$CORE" "mkdir -p /tmp/ran_collect && nohup bash $REPO_DIR/scripts/collect_system_metrics.sh core > /tmp/ran_collect/system_metrics_core.log 2>&1 &"
$SSH "$UEHOST1" "cd $REPO_DIR && nohup bash scripts/launch_uehost1_collectors.sh > /tmp/ran_collect/uehost1_collectors.log 2>&1 &"

log "Waiting 10 s for collectors to warm up..."
sleep 10

# ---------------------------------------------------------------------------
# PHASE 2: Connect UE51 to gNB1
# ---------------------------------------------------------------------------
phase "UE51_ATTACH_GNB1"
log "Starting UE51 on uehost2 → attaching to gnb1..."
LB_TRIGGER_START_MS=$(date +%s%3N)

$SSH "$UEHOST2" "cd $REPO_DIR && nohup bash scripts/deploy_ues_51_100_v2.sh 51 51 > /tmp/ran_collect/ue51_attach.log 2>&1 &"
log "UE51 start command sent. Waiting 20 s for attach..."
sleep 20

UE51_STATUS=$($SSH "$UEHOST2" "ip netns list 2>/dev/null | grep -c ue51 || echo 0")
log "UE51 netns present: $UE51_STATUS"

# ---------------------------------------------------------------------------
# PHASE 3: Ramp iperf3 throughput to 500 Mbps across all 51 UEs
# ---------------------------------------------------------------------------
phase "THROUGHPUT_RAMP_500MBPS"
log "Starting iperf3 ramp to 500 Mbps across all 51 UEs..."

# Start iperf3 server on core if not running
$SSH "$CORE" "pkill iperf3 2>/dev/null; sleep 1; nohup bash $REPO_DIR/scripts/start_iperf3_server_core.sh > /tmp/ran_collect/iperf3_server.log 2>&1 &"
sleep 3

# Ramp throughput on uehost1 (UEs 1-50) and uehost2 (UE51)
$SSH "$UEHOST1" "cd $REPO_DIR && nohup bash scripts/run_iperf_500mbps.sh 1 50 > /tmp/ran_collect/iperf_uehost1.log 2>&1 &"
$SSH "$UEHOST2" "cd $REPO_DIR && nohup bash scripts/run_iperf_500mbps.sh 51 51 > /tmp/ran_collect/iperf_uehost2.log 2>&1 &"

log "Throughput ramp started. Collecting 30 s of baseline at load..."
sleep 30

# Record throughput baseline
$SSH "$UEHOST1" "cd $REPO_DIR && python3 scripts/build_master_v4.py --phase THROUGHPUT_RAMP_500MBPS --out /tmp/ran_collect/results/ 2>/dev/null || true"

# ---------------------------------------------------------------------------
# PHASE 4: Record LB trigger timestamp and execute load balance
# ---------------------------------------------------------------------------
phase "LB_TRIGGER"
LB_TS_MS=$(date +%s%3N)
echo "lb_trigger_ts_ms=$LB_TS_MS" | tee "$LOG_DIR/lb_trigger.txt"
$SSH "$UEHOST2" "echo 'lb_trigger_ts_ms=$LB_TS_MS' > /tmp/ran_collect/lb_trigger.txt"
log "LB trigger timestamp: $LB_TS_MS ms"

# Start handover monitor on uehost2 BEFORE triggering
$SSH "$UEHOST2" "cd $REPO_DIR && nohup bash scripts/collect_ue51_handover.sh > /tmp/ran_collect/ue51_handover_monitor.log 2>&1 &"
sleep 1

# Execute load balance: disconnect UE51 from gnb1, connect to gnb2
log "Executing UE51 load balance: gnb1 → gnb2..."
$SSH "$UEHOST2" "cd $REPO_DIR && bash scripts/run_ue51_lb_experiment.sh > /tmp/ran_collect/ue51_lb.log 2>&1" &
LB_PID=$!

# ---------------------------------------------------------------------------
# PHASE 5: Monitor transition
# ---------------------------------------------------------------------------
phase "LB_TRANSITION"
log "Monitoring LB transition (max 120 s)..."

for i in $(seq 1 24); do
  sleep 5
  STATUS=$($SSH "$UEHOST2" "cat /tmp/ran_collect/ue51_handover.csv 2>/dev/null | tail -1 || echo 'waiting'")
  log "  T+$((i*5))s handover status: $STATUS"
  # Check if UE51 is attached to gnb2
  ATTACHED=$($SSH "$GNB2" "ps aux 2>/dev/null | grep -c '[s]rsue' || echo 0")
  if [[ "$ATTACHED" -ge 1 ]]; then
    log "✅ UE51 detected on gnb2 at T+$((i*5))s"
    break
  fi
done

LB_COMPLETE_MS=$(date +%s%3N)
HANDOVER_DURATION_MS=$((LB_COMPLETE_MS - LB_TS_MS))
log "Handover duration estimate: ${HANDOVER_DURATION_MS} ms"
echo "HANDOVER_DURATION_MS=$HANDOVER_DURATION_MS" | tee "$LOG_DIR/handover_duration.txt"
$SSH "$UEHOST2" "echo 'HANDOVER_DURATION_MS=$HANDOVER_DURATION_MS' >> /tmp/ran_collect/ue51_handover_summary.txt"

# ---------------------------------------------------------------------------
# PHASE 6: Post-LB steady state collection
# ---------------------------------------------------------------------------
phase "POST_LB_STEADY"
log "Collecting post-LB steady state for 60 s..."
sleep 60

# ---------------------------------------------------------------------------
# PHASE 7: Collect all logs from all nodes
# ---------------------------------------------------------------------------
phase "LOG_COLLECTION"
log "Pulling all CSV logs from remote nodes..."

for node_info in "gnb1:$GNB1" "gnb2:$GNB2" "core:$CORE" "uehost2:$UEHOST2"; do
  NODE="${node_info%%:*}"
  ADDR="${node_info##*:}"
  mkdir -p "$RESULTS_DIR/$NODE"
  scp -o StrictHostKeyChecking=no "$ADDR:/tmp/ran_collect/*.csv" "$RESULTS_DIR/$NODE/" 2>/dev/null || true
  scp -o StrictHostKeyChecking=no "$ADDR:/tmp/ran_collect/*.txt" "$RESULTS_DIR/$NODE/" 2>/dev/null || true
  log "  Pulled logs from $NODE"
done

# ---------------------------------------------------------------------------
# PHASE 8: Analysis & key findings
# ---------------------------------------------------------------------------
phase "ANALYSIS"
log "Running analysis to generate key findings..."
python3 "$REPO_DIR/scripts/analyze_lb_results.py" \
  --results-dir "$RESULTS_DIR" \
  --out "$RESULTS_DIR/key_findings.txt" \
  --csv "$RESULTS_DIR/lb_analysis.csv" 2>/dev/null || \
  log "WARNING: analyze_lb_results.py not found or failed — check $RESULTS_DIR manually"

# ---------------------------------------------------------------------------
# PHASE 9: Stop all collectors
# ---------------------------------------------------------------------------
phase "CLEANUP"
log "Stopping all background collectors..."
for node in "$GNB1" "$GNB2" "$CORE" "$UEHOST1" "$UEHOST2"; do
  $SSH "$node" "pkill -f collect_system_metrics || true; pkill -f deep_sysmon || true; pkill -f collect_rich_gnb || true; pkill -f collect_power || true" 2>/dev/null || true
done

phase "COMPLETE"
log "=== Experiment complete ==="
log "Results: $RESULTS_DIR"
log "Key findings: $RESULTS_DIR/key_findings.txt"
log "Handover duration: ${HANDOVER_DURATION_MS} ms"
