#!/usr/bin/env bash
# =============================================================================
# master_lb_experiment.sh  —  POWDER Load-Balancing Single-Command Launcher
# =============================================================================
# Orchestrates the full experiment pipeline in order:
#   1. Deploy  → pre-flight checks, git pull, sync scripts/configs on all nodes
#   2. Collect → start ALL background collectors on gnb1, gnb2, core, uehost2
#   3. Run     → 7-phase LB orchestrator on uehost1
#   4. Harvest → pull all CSVs back to uehost1 results/
#   5. Analyze → run analyze_lb_results.py to produce key-finding report
#
# Usage:
#   ./master_lb_experiment.sh [--dry-run] [--skip-deploy] [--skip-analyze]
#
# Run from: uehost1 (pc808)
# =============================================================================

set -euo pipefail

###############################################################################
# CONFIG
###############################################################################
REPO_DIR="${HOME}/POWDER-Load-Balancing"
SCRIPTS_DIR="${REPO_DIR}/scripts"
COLLECT_DIR="/tmp/ran_collect"
RESULTS_DIR="${COLLECT_DIR}/results"
LOG="${COLLECT_DIR}/master_experiment.log"

GNB1="saish@pc818.emulab.net"
GNB2="saish@pc802.emulab.net"
CORE="saish@pc811.emulab.net"
UEHOST2="saish@pc801.emulab.net"

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

DRY_RUN=false
SKIP_DEPLOY=false
SKIP_ANALYZE=false

###############################################################################
# ARG PARSING
###############################################################################
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)      DRY_RUN=true ;;
    --skip-deploy)  SKIP_DEPLOY=true ;;
    --skip-analyze) SKIP_ANALYZE=true ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
  shift
done

###############################################################################
# HELPERS
###############################################################################
ts()  { date '+%Y-%m-%dT%H:%M:%S'; }
log() { echo "[$(ts)] $*" | tee -a "$LOG"; }

rssh() {
  local host="$1"; shift
  if $DRY_RUN; then
    echo "[DRY-RUN] ssh $host: $*"
    return 0
  fi
  ssh $SSH_OPTS "$host" "$@"
}

rscpTo() {
  # rscpTo <host> <local_src> <remote_dst>
  local host="$1" src="$2" dst="$3"
  if $DRY_RUN; then
    echo "[DRY-RUN] scp $src -> $host:$dst"
    return 0
  fi
  scp $SSH_OPTS "$src" "$host:$dst"
}

rscpFrom() {
  # rscpFrom <host> <remote_src> <local_dst>
  local host="$1" src="$2" dst="$3"
  if $DRY_RUN; then
    echo "[DRY-RUN] scp $host:$src -> $dst"
    return 0
  fi
  scp $SSH_OPTS "$host:$src" "$dst"
}

check_required() {
  local missing=0
  for cmd in ssh scp python3; do
    if ! command -v "$cmd" &>/dev/null; then
      log "ERROR: Required command not found: $cmd"
      missing=1
    fi
  done
  [[ $missing -eq 0 ]] || exit 1
}

###############################################################################
# PHASE 0 — LOCAL SETUP
###############################################################################
phase0_local_setup() {
  log "=== PHASE 0: Local setup ==="
  mkdir -p "$COLLECT_DIR" "$RESULTS_DIR"
  mkdir -p "$RESULTS_DIR"/{gnb1,gnb2,core,uehost2}
  echo "0_setup" > "$COLLECT_DIR/phase.txt"
  log "Directories created. Log: $LOG"
}

###############################################################################
# PHASE 1 — DEPLOY (pre-flight + sync)
###############################################################################
phase1_deploy() {
  if $SKIP_DEPLOY; then
    log "=== PHASE 1: SKIPPED (--skip-deploy) ==="
    return 0
  fi
  log "=== PHASE 1: Deploy — pre-flight checks on all nodes ==="

  if [[ ! -x "${SCRIPTS_DIR}/deploy_experiment.sh" ]]; then
    log "ERROR: deploy_experiment.sh not found or not executable at ${SCRIPTS_DIR}"
    exit 1
  fi

  bash "${SCRIPTS_DIR}/deploy_experiment.sh" $( $DRY_RUN && echo "--dry-run" )
  log "Deploy complete."
}

###############################################################################
# PHASE 2 — START ALL COLLECTORS
###############################################################################
phase2_start_collectors() {
  log "=== PHASE 2: Starting background collectors on all nodes ==="

  # ---- gNB1 collectors ----
  log "  Starting collectors on gNB1 (pc818)..."
  rssh "$GNB1" "
    mkdir -p /tmp/ran_collect
    nohup bash /tmp/ran_collect/scripts/collect_system_metrics.sh 2 \
      > /tmp/ran_collect/sysmet_gnb1.log 2>&1 &
    echo \$! > /tmp/ran_collect/sysmet_gnb1.pid

    nohup bash /tmp/ran_collect/scripts/collect_gnb_metrics.sh gnb1 \
      > /tmp/ran_collect/gnbmet_gnb1.log 2>&1 &
    echo \$! > /tmp/ran_collect/gnbmet_gnb1.pid

    nohup sudo bash /tmp/ran_collect/scripts/collect_power.sh 1 \
      > /tmp/ran_collect/power_gnb1.log 2>&1 &
    echo \$! > /tmp/ran_collect/power_gnb1.pid

    nohup bash /tmp/ran_collect/scripts/collect_rich_gnb.sh gnb1 2 \
      > /tmp/ran_collect/rich_gnb1.log 2>&1 &
    echo \$! > /tmp/ran_collect/rich_gnb1.pid

    nohup python3 /tmp/ran_collect/scripts/deep_sysmon.py gnb1 \
      > /tmp/ran_collect/deepsys_gnb1.log 2>&1 &
    echo \$! > /tmp/ran_collect/deepsys_gnb1.pid

    nohup bash /tmp/ran_collect/scripts/collect_perf_ipc.sh gnb1 5 \
      > /tmp/ran_collect/perfipc_gnb1.log 2>&1 &
    echo \$! > /tmp/ran_collect/perfipc_gnb1.pid

    echo 'gnb1_collectors_started'
  " || log "WARN: Some gNB1 collectors failed to start"

  # ---- gNB2 collectors ----
  log "  Starting collectors on gNB2 (pc802)..."
  rssh "$GNB2" "
    mkdir -p /tmp/ran_collect
    nohup bash /tmp/ran_collect/scripts/collect_system_metrics.sh 2 \
      > /tmp/ran_collect/sysmet_gnb2.log 2>&1 &
    echo \$! > /tmp/ran_collect/sysmet_gnb2.pid

    nohup bash /tmp/ran_collect/scripts/collect_gnb_metrics.sh gnb2 \
      > /tmp/ran_collect/gnbmet_gnb2.log 2>&1 &
    echo \$! > /tmp/ran_collect/gnbmet_gnb2.pid

    nohup sudo bash /tmp/ran_collect/scripts/collect_power.sh 1 \
      > /tmp/ran_collect/power_gnb2.log 2>&1 &
    echo \$! > /tmp/ran_collect/power_gnb2.pid

    nohup bash /tmp/ran_collect/scripts/collect_rich_gnb.sh gnb2 2 \
      > /tmp/ran_collect/rich_gnb2.log 2>&1 &
    echo \$! > /tmp/ran_collect/rich_gnb2.pid

    nohup python3 /tmp/ran_collect/scripts/deep_sysmon.py gnb2 \
      > /tmp/ran_collect/deepsys_gnb2.log 2>&1 &
    echo \$! > /tmp/ran_collect/deepsys_gnb2.pid

    nohup bash /tmp/ran_collect/scripts/collect_perf_ipc.sh gnb2 5 \
      > /tmp/ran_collect/perfipc_gnb2.log 2>&1 &
    echo \$! > /tmp/ran_collect/perfipc_gnb2.pid

    echo 'gnb2_collectors_started'
  " || log "WARN: Some gNB2 collectors failed to start"

  # ---- Core collectors ----
  log "  Starting collectors on core (pc811)..."
  rssh "$CORE" "
    mkdir -p /tmp/ran_collect
    nohup bash /tmp/ran_collect/scripts/collect_system_metrics.sh 2 \
      > /tmp/ran_collect/sysmet_core.log 2>&1 &
    echo \$! > /tmp/ran_collect/sysmet_core.pid
    echo 'core_collectors_started'
  " || log "WARN: Core collector failed to start"

  # ---- uehost2 handover monitor ----
  log "  Starting handover monitor on uehost2 (pc801)..."
  rssh "$UEHOST2" "
    mkdir -p /tmp/ran_collect
    nohup bash /tmp/ran_collect/scripts/collect_ue51_handover.sh \
      > /tmp/ran_collect/ue51_handover.log 2>&1 &
    echo \$! > /tmp/ran_collect/handover_monitor.pid
    echo 'uehost2_monitor_started'
  " || log "WARN: uehost2 handover monitor failed to start"

  log "All collectors started. Waiting 5s for them to warm up..."
  sleep 5
}

###############################################################################
# PHASE 3 — RUN EXPERIMENT
###############################################################################
phase3_run_experiment() {
  log "=== PHASE 3: Running 7-phase LB experiment ==="

  if [[ ! -x "${SCRIPTS_DIR}/run_ue51_lb_experiment.sh" ]]; then
    log "ERROR: run_ue51_lb_experiment.sh not found or not executable"
    exit 1
  fi

  bash "${SCRIPTS_DIR}/run_ue51_lb_experiment.sh" 2>&1 | tee -a "$LOG"
  log "7-phase experiment complete."
}

###############################################################################
# PHASE 4 — STOP COLLECTORS + HARVEST DATA
###############################################################################
phase4_harvest() {
  log "=== PHASE 4: Stopping collectors and harvesting data ==="

  # Stop all collectors gracefully
  for node_info in "gnb1:$GNB1" "gnb2:$GNB2" "core:$CORE" "uehost2:$UEHOST2"; do
    local label="${node_info%%:*}"
    local host="${node_info##*:}"
    log "  Stopping collectors on ${label}..."
    rssh "$host" "
      for pidfile in /tmp/ran_collect/*.pid; do
        [ -f \"\$pidfile\" ] || continue
        pid=\$(cat \"\$pidfile\")
        if kill -0 \"\$pid\" 2>/dev/null; then
          kill -TERM \"\$pid\" 2>/dev/null || true
        fi
        rm -f \"\$pidfile\"
      done
      echo '${label}_collectors_stopped'
    " || log "WARN: Could not stop some ${label} collectors"
  done

  sleep 3  # flush final writes

  # Pull results from each node
  log "  Pulling results from gNB1..."
  rssh "$GNB1" "ls /tmp/ran_collect/*.csv 2>/dev/null || true" | while read -r f; do
    rscpFrom "$GNB1" "$f" "${RESULTS_DIR}/gnb1/" 2>/dev/null || true
  done
  rscpFrom "$GNB1" "/tmp/ran_collect/*.csv"  "${RESULTS_DIR}/gnb1/" 2>/dev/null || true
  rscpFrom "$GNB1" "/tmp/ran_collect/*.log"  "${RESULTS_DIR}/gnb1/" 2>/dev/null || true

  log "  Pulling results from gNB2..."
  rscpFrom "$GNB2" "/tmp/ran_collect/*.csv"  "${RESULTS_DIR}/gnb2/" 2>/dev/null || true
  rscpFrom "$GNB2" "/tmp/ran_collect/*.log"  "${RESULTS_DIR}/gnb2/" 2>/dev/null || true

  log "  Pulling results from core..."
  rscpFrom "$CORE" "/tmp/ran_collect/*.csv"  "${RESULTS_DIR}/core/" 2>/dev/null || true

  log "  Pulling results from uehost2..."
  rscpFrom "$UEHOST2" "/tmp/ran_collect/*.csv"  "${RESULTS_DIR}/uehost2/" 2>/dev/null || true
  rscpFrom "$UEHOST2" "/tmp/ran_collect/*.txt"  "${RESULTS_DIR}/uehost2/" 2>/dev/null || true

  # Also pull local uehost1 results
  mkdir -p "${RESULTS_DIR}/uehost1"
  cp "$COLLECT_DIR"/*.csv "${RESULTS_DIR}/uehost1/" 2>/dev/null || true
  cp "$COLLECT_DIR"/*.txt "${RESULTS_DIR}/uehost1/" 2>/dev/null || true

  log "Harvest complete. Results in: ${RESULTS_DIR}"
  find "${RESULTS_DIR}" -name "*.csv" | sort | tee -a "$LOG"
}

###############################################################################
# PHASE 5 — ANALYZE
###############################################################################
phase5_analyze() {
  if $SKIP_ANALYZE; then
    log "=== PHASE 5: SKIPPED (--skip-analyze) ==="
    return 0
  fi
  log "=== PHASE 5: Running post-experiment analysis ==="

  local analyzer="${SCRIPTS_DIR}/analyze_lb_results.py"
  if [[ ! -f "$analyzer" ]]; then
    log "WARN: analyze_lb_results.py not found at ${analyzer}. Skipping."
    return 0
  fi

  python3 "$analyzer" \
    --results-dir "${RESULTS_DIR}" \
    --output "${COLLECT_DIR}/analysis_report.txt" \
    2>&1 | tee -a "$LOG"

  if [[ -f "${COLLECT_DIR}/analysis_report.txt" ]]; then
    log "=== ANALYSIS REPORT ==="
    cat "${COLLECT_DIR}/analysis_report.txt" | tee -a "$LOG"
  fi
}

###############################################################################
# SUMMARY
###############################################################################
print_summary() {
  log "==================================================================="
  log "EXPERIMENT COMPLETE"
  log "==================================================================="
  log "Results directory : ${RESULTS_DIR}"
  log "Master log        : ${LOG}"
  [[ -f "${COLLECT_DIR}/analysis_report.txt" ]] && \
    log "Analysis report   : ${COLLECT_DIR}/analysis_report.txt"
  [[ -f "${COLLECT_DIR}/experiment_summary.txt" ]] && \
    log "Experiment summary: ${COLLECT_DIR}/experiment_summary.txt"
  log "CSV files collected:"
  find "${RESULTS_DIR}" -name "*.csv" 2>/dev/null | sort | while read -r f; do
    local lines
    lines=$(wc -l < "$f" 2>/dev/null || echo "?")
    log "  ${lines} rows  ${f}"
  done
  log "==================================================================="
}

###############################################################################
# TRAP — cleanup on abort
###############################################################################
cleanup_on_exit() {
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    log "ERROR: master_lb_experiment.sh exited with code $rc"
    log "Attempting emergency collector shutdown..."
    for host in "$GNB1" "$GNB2" "$CORE" "$UEHOST2"; do
      ssh $SSH_OPTS "$host" \
        "pkill -f 'collect_system_metrics\|collect_gnb_metrics\|collect_power\|collect_rich_gnb\|deep_sysmon\|collect_perf_ipc\|collect_ue51_handover' 2>/dev/null || true" \
        2>/dev/null || true
    done
  fi
}
trap cleanup_on_exit EXIT

###############################################################################
# MAIN
###############################################################################
main() {
  check_required
  mkdir -p "$COLLECT_DIR"
  log "=================================================================="
  log "POWDER Load-Balancing Master Experiment  (dry_run=${DRY_RUN})"
  log "=================================================================="

  phase0_local_setup
  phase1_deploy
  phase2_start_collectors
  phase3_run_experiment
  phase4_harvest
  phase5_analyze
  print_summary
}

main "$@"
