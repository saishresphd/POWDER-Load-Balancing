#!/usr/bin/env bash
# =============================================================================
# master_lb_9ue_experiment.sh  —  9-UE Load-Balancing Single-Command Launcher
# =============================================================================
# Migrates UE40-49 from gNB1 → gNB2 and collects all data needed to extend
# key findings from the IEEE paper (10949489):
#
#   Eq.2  Power-law model:  P(load) = α · load^β + γ
#   Eq.3  Power model:      Ptotal = Pbase + NaU·PaU + NUi·PUi
#   Eq.4  Savings model:    Psaved = Pactive - Pswitched
#   KF-3  CPU savings from UE disconnection (9-UE extension)
#   KF-4  Marginal power cost per migrated UE on target gNB
#
# Pipeline:
#   Phase 0  Pre-flight: directory setup, connectivity checks
#   Phase 1  Deploy:     sync scripts/configs to all nodes
#   Phase 2  Collect:    start all background collectors (power, RAN, CPU, IPC)
#   Phase 3  Run:        9-phase LB orchestrator (detach UE40-49, attach on gNB2)
#   Phase 4  Harvest:    pull all CSVs/logs back to uehost1 results/
#   Phase 5  Analyze:    run analyze_lb_results.py → key-finding report
#
# Usage:
#   ./master_lb_9ue_experiment.sh [--dry-run] [--skip-deploy] [--skip-analyze]
#   SKIP_UE40=true ./master_lb_9ue_experiment.sh   # keep UE40 on gNB1 as control
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
RESULTS_DIR="${COLLECT_DIR}/results_9ue"
LOG="${COLLECT_DIR}/master_lb_9ue.log"

GNB1="saish@pc818.emulab.net"
GNB2="saish@pc802.emulab.net"
CORE="saish@pc811.emulab.net"

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

DRY_RUN=false
SKIP_DEPLOY=false
SKIP_ANALYZE=false

export SKIP_UE40="${SKIP_UE40:-false}"   # pass through to run_ue40_49_lb_experiment.sh

###############################################################################
# ARG PARSING
###############################################################################
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)      DRY_RUN=true ;;
        --skip-deploy)  SKIP_DEPLOY=true ;;
        --skip-analyze) SKIP_ANALYZE=true ;;
        --skip-ue40)    export SKIP_UE40=true ;;
        *) echo "Unknown flag: $1  (valid: --dry-run --skip-deploy --skip-analyze --skip-ue40)"; exit 1 ;;
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
    $DRY_RUN && { echo "[DRY-RUN] ssh $host: $*"; return 0; }
    ssh $SSH_OPTS "$host" "$@"
}

rscpTo() {
    local host="$1" src="$2" dst="$3"
    $DRY_RUN && { echo "[DRY-RUN] scp $src → $host:$dst"; return 0; }
    scp $SSH_OPTS "$src" "$host:$dst"
}

rscpFrom() {
    local host="$1" src="$2" dst="$3"
    $DRY_RUN && { echo "[DRY-RUN] scp $host:$src → $dst"; return 0; }
    scp $SSH_OPTS "$host:$src" "$dst" 2>/dev/null || true
}

check_required() {
    local missing=0
    for cmd in ssh scp python3; do
        command -v "$cmd" &>/dev/null || { log "ERROR: required command not found: $cmd"; missing=1; }
    done
    [[ $missing -eq 0 ]] || exit 1
}

###############################################################################
# PHASE 0 — LOCAL SETUP
###############################################################################
phase0_local_setup() {
    log "=== PHASE 0: Local setup ==="
    mkdir -p "$COLLECT_DIR" "$RESULTS_DIR"
    mkdir -p "$RESULTS_DIR"/{gnb1,gnb2,core}
    echo "0_setup" > "$COLLECT_DIR/phase.txt"
    log "Directories ready. Log: $LOG"
}

###############################################################################
# PHASE 1 — DEPLOY (pre-flight + sync)
###############################################################################
phase1_deploy() {
    $SKIP_DEPLOY && { log "=== PHASE 1: SKIPPED (--skip-deploy) ==="; return 0; }
    log "=== PHASE 1: Deploy — connectivity check + sync scripts/configs ==="

    # ── Connectivity check ───────────────────────────────────────────────────
    local ok=1
    for host in "$GNB1" "$GNB2" "$CORE"; do
        if rssh "$host" "echo pong" 2>/dev/null | grep -q pong; then
            log "  ✓ $host reachable"
        else
            log "  ✗ $host UNREACHABLE"
            ok=0
        fi
    done
    [[ $ok -eq 1 ]] || { log "ERROR: Not all nodes reachable. Abort."; exit 1; }

    # ── Sync scripts to all nodes ────────────────────────────────────────────
    log "  Syncing scripts to remote nodes..."
    for host in "$GNB1" "$GNB2"; do
        rssh "$host" "mkdir -p $COLLECT_DIR"
        for script in \
            "${SCRIPTS_DIR}/collect_system_metrics.sh" \
            "${SCRIPTS_DIR}/collect_gnb_metrics.sh" \
            "${SCRIPTS_DIR}/collect_rich_gnb.sh" \
            "${SCRIPTS_DIR}/collect_power.sh" \
            "${SCRIPTS_DIR}/deep_sysmon.py" \
            "${SCRIPTS_DIR}/collect_perf_ipc.sh"; do
            [ -f "$script" ] && rscpTo "$host" "$script" "$COLLECT_DIR/" 2>/dev/null || true
        done
    done

    # ── Sync gnb2 enb configs for UE40-49 ───────────────────────────────────
    log "  Syncing gnb2 enb_ue40..49 configs to gNB2..."
    for i in $(seq 40 49); do
        conf="${REPO_DIR}/configs/gnb2/enb_ue${i}.conf"
        if [ -f "$conf" ]; then
            rscpTo "$GNB2" "$conf" "/etc/srsenb/enb_ue${i}.conf" 2>/dev/null || \
            rscpTo "$GNB2" "$conf" "$COLLECT_DIR/enb_ue${i}.conf" 2>/dev/null || \
            log "  WARN: could not push enb_ue${i}.conf to gNB2"
        else
            log "  WARN: $conf not found — skipping"
        fi
    done

    # ── Sync ue gnb2 configs to uehost1 local collect dir ───────────────────
    log "  Staging ue40_gnb2..ue49_gnb2 configs locally..."
    mkdir -p "$COLLECT_DIR/configs/ues"
    for i in $(seq 40 49); do
        conf="${REPO_DIR}/configs/ues/ue${i}_gnb2.conf"
        [ -f "$conf" ] && cp "$conf" "$COLLECT_DIR/configs/ues/" 2>/dev/null || \
        log "  WARN: $conf not found"
    done

    # ── Also sync the run script and handover monitor ────────────────────────
    cp "${SCRIPTS_DIR}/run_ue40_49_lb_experiment.sh" "$COLLECT_DIR/" 2>/dev/null || true
    cp "${SCRIPTS_DIR}/collect_ue40_49_handover.sh"  "$COLLECT_DIR/" 2>/dev/null || true

    log "Deploy complete."
}

###############################################################################
# PHASE 2 — PRE-LAUNCH COLLECTOR VERIFICATION
###############################################################################
phase2_verify_collectors() {
    log "=== PHASE 2: Verifying collector scripts are present on nodes ==="

    for host in "$GNB1" "$GNB2"; do
        for script in collect_system_metrics.sh collect_gnb_metrics.sh; do
            if rssh "$host" "test -f $COLLECT_DIR/$script" 2>/dev/null; then
                log "  ✓ $host:$COLLECT_DIR/$script"
            else
                log "  WARN: $host missing $script — re-syncing"
                rscpTo "$host" "${SCRIPTS_DIR}/${script}" "$COLLECT_DIR/" 2>/dev/null || true
            fi
        done
    done

    # Verify UE gnb2 configs are in place
    for i in $(seq 40 49); do
        conf="$COLLECT_DIR/configs/ues/ue${i}_gnb2.conf"
        [ -f "$conf" ] && log "  ✓ ue${i}_gnb2.conf" || \
        log "  WARN: $conf missing — will attempt fallback during experiment"
    done
    log "Verification complete."
}

###############################################################################
# PHASE 3 — RUN EXPERIMENT
###############################################################################
phase3_run_experiment() {
    log "=== PHASE 3: Running 9-UE LB experiment ==="

    local exp_script="${COLLECT_DIR}/run_ue40_49_lb_experiment.sh"
    if [[ ! -f "$exp_script" ]]; then
        # Try from repo scripts dir
        exp_script="${SCRIPTS_DIR}/run_ue40_49_lb_experiment.sh"
    fi
    [[ -f "$exp_script" ]] || { log "ERROR: run_ue40_49_lb_experiment.sh not found"; exit 1; }
    [[ -x "$exp_script" ]] || chmod +x "$exp_script"

    if $DRY_RUN; then
        log "[DRY-RUN] Would execute: $exp_script"
        return 0
    fi

    SKIP_UE40="$SKIP_UE40" bash "$exp_script" 2>&1 | tee -a "$LOG"
    log "9-UE LB experiment complete."
}

###############################################################################
# PHASE 4 — HARVEST DATA
###############################################################################
phase4_harvest() {
    log "=== PHASE 4: Harvesting all results ==="

    # Pull from gNB1
    log "  Pulling from gNB1..."
    rscpFrom "$GNB1" "/tmp/ran_collect/*.csv"  "${RESULTS_DIR}/gnb1/"
    rscpFrom "$GNB1" "/tmp/ran_collect/*.txt"  "${RESULTS_DIR}/gnb1/"
    rscpFrom "$GNB1" "/tmp/ran_collect/*.log"  "${RESULTS_DIR}/gnb1/"

    # Pull from gNB2
    log "  Pulling from gNB2..."
    rscpFrom "$GNB2" "/tmp/ran_collect/*.csv"  "${RESULTS_DIR}/gnb2/"
    rscpFrom "$GNB2" "/tmp/ran_collect/*.txt"  "${RESULTS_DIR}/gnb2/"
    rscpFrom "$GNB2" "/tmp/ran_collect/*.log"  "${RESULTS_DIR}/gnb2/"

    # Pull from Core
    log "  Pulling from Core..."
    rscpFrom "$CORE" "/tmp/ran_collect/*.csv"  "${RESULTS_DIR}/core/"

    # Copy local uehost1 files
    cp "$COLLECT_DIR"/*.csv  "$RESULTS_DIR/" 2>/dev/null || true
    cp "$COLLECT_DIR"/*.json "$RESULTS_DIR/" 2>/dev/null || true
    cp "$COLLECT_DIR"/*.txt  "$RESULTS_DIR/" 2>/dev/null || true

    log "Harvest complete. Results in: ${RESULTS_DIR}"
    find "${RESULTS_DIR}" -name "*.csv" 2>/dev/null | sort | while read -r f; do
        lines=$(wc -l < "$f" 2>/dev/null || echo "?")
        log "  ${lines} rows  ${f}"
    done
}

###############################################################################
# PHASE 5 — ANALYZE
###############################################################################
phase5_analyze() {
    $SKIP_ANALYZE && { log "=== PHASE 5: SKIPPED (--skip-analyze) ==="; return 0; }
    log "=== PHASE 5: Running post-experiment analysis ==="

    local analyzer
    for candidate in \
        "${SCRIPTS_DIR}/analyze_lb_results.py" \
        "${REPO_DIR}/analyze_lb_results.py" \
        "${COLLECT_DIR}/analyze_lb_results.py"; do
        [ -f "$candidate" ] && analyzer="$candidate" && break
    done

    if [[ -z "${analyzer:-}" ]]; then
        log "WARN: analyze_lb_results.py not found — skipping analysis"
        return 0
    fi

    $DRY_RUN && { log "[DRY-RUN] Would run: python3 $analyzer --results-dir $RESULTS_DIR"; return 0; }

    python3 "$analyzer" \
        --results-dir "${RESULTS_DIR}" \
        --output "${COLLECT_DIR}/analysis_report_9ue.txt" \
        2>&1 | tee -a "$LOG"

    [[ -f "${COLLECT_DIR}/analysis_report_9ue.txt" ]] && {
        log "=== ANALYSIS REPORT ==="
        cat "${COLLECT_DIR}/analysis_report_9ue.txt" | tee -a "$LOG"
    }
}

###############################################################################
# SUMMARY
###############################################################################
print_summary() {
    log "==================================================================="
    log "9-UE LOAD-BALANCING EXPERIMENT COMPLETE"
    log "==================================================================="
    log "UEs migrated         : UE40-49 (gNB1 → gNB2)"
    log "SKIP_UE40            : ${SKIP_UE40}"
    log "Results directory    : ${RESULTS_DIR}"
    log "Master log           : ${LOG}"
    [[ -f "${COLLECT_DIR}/lb9ue_experiment_summary.txt" ]] && \
        log "Experiment summary   : ${COLLECT_DIR}/lb9ue_experiment_summary.txt"
    [[ -f "${COLLECT_DIR}/analysis_report_9ue.txt" ]] && \
        log "Analysis report      : ${COLLECT_DIR}/analysis_report_9ue.txt"
    [[ -f "${COLLECT_DIR}/ue40_49_handover_summary.txt" ]] && \
        log "Handover summary     : ${COLLECT_DIR}/ue40_49_handover_summary.txt"
    log ""
    log "Key paper equations fed by this data:"
    log "  Eq.3 — Ptotal = Pbase + NaU·PaU + NUi·PUi"
    log "         → gnb1: NaU 50→40 | gnb2: NaU 0→9"
    log "  Eq.4 — Psaved = Pactive - Pswitched"
    log "         → Pactive from phase3_hold_500mbps_prelb"
    log "         → Pswitched from phase6_post_lb_steady_state"
    log ""
    log "CSV files collected:"
    find "${RESULTS_DIR}" -name "*.csv" 2>/dev/null | sort | while read -r f; do
        lines=$(wc -l < "$f" 2>/dev/null || echo "?")
        log "  ${lines} rows  ${f}"
    done
    log "==================================================================="
}

###############################################################################
# TRAP — emergency cleanup on abort
###############################################################################
cleanup_on_exit() {
    local rc=$?
    [[ $rc -eq 0 ]] && return 0
    log "ERROR: master_lb_9ue_experiment.sh exited with code $rc"
    log "Attempting emergency collector shutdown..."
    for host in "$GNB1" "$GNB2" "$CORE"; do
        ssh $SSH_OPTS "$host" \
            "pkill -f 'collect_system_metrics\|collect_gnb_metrics\|collect_power\|collect_rich_gnb\|deep_sysmon\|collect_perf_ipc' 2>/dev/null || true" \
            2>/dev/null || true
    done
}
trap cleanup_on_exit EXIT

###############################################################################
# MAIN
###############################################################################
main() {
    check_required
    mkdir -p "$COLLECT_DIR"
    log "=================================================================="
    log "POWDER 9-UE Load-Balancing Master Experiment"
    log "  dry_run=${DRY_RUN}  skip_deploy=${SKIP_DEPLOY}  skip_ue40=${SKIP_UE40}"
    log "=================================================================="

    phase0_local_setup
    phase1_deploy
    phase2_verify_collectors
    phase3_run_experiment
    phase4_harvest
    phase5_analyze
    print_summary
}

main "$@"
