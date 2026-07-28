#!/usr/bin/env bash
# =============================================================================
# deploy_experiment.sh
# POWDER Load-Balancing Experiment — Deployment & Pre-flight Helper
#
# Run this script from uehost1 (pc808 / 10.10.1.4) as user 'saish'.
# It will:
#   1. Pull branch 110-ue-scale on every testbed node
#   2. Sync scripts → /tmp/ran_collect/ and configs → /etc/srsran/
#   3. Create the /tmp/ran_collect/ output directory everywhere
#   4. Verify every required binary / Python package / kernel feature
#   5. Print a colour-coded pass/fail checklist per node
#
# Usage:
#   chmod +x deploy_experiment.sh
#   bash deploy_experiment.sh [--dry-run] [--skip-pull] [--node <name>]
#
#   --dry-run     : Print what would be done; make no changes
#   --skip-pull   : Skip git pull (useful if network is slow; scripts already synced)
#   --node <name> : Only deploy to one specific node (core|gnb1|gnb2|uehost1|uehost2)
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}[PASS]${NC} $*"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "  ${RED}[FAIL]${NC} $*"; }
info() { echo -e "  [INFO] $*"; }
hdr()  { echo -e "\n${YELLOW}=== $* ===${NC}"; }

# ---------------------------------------------------------------------------
# Node definitions
# ---------------------------------------------------------------------------
declare -A NODE_IP=(
  [core]="10.10.1.1"
  [gnb1]="10.10.1.2"
  [gnb2]="10.10.1.3"
  [uehost1]="10.10.1.4"
  [uehost2]="10.10.1.5"
)
declare -A NODE_HOST=(
  [core]="pc811.emulab.net"
  [gnb1]="pc818.emulab.net"
  [gnb2]="pc802.emulab.net"
  [uehost1]="pc808.emulab.net"
  [uehost2]="pc801.emulab.net"
)
SSH_USER="saish"
BRANCH="110-ue-scale"
REPO_URL="https://github.com/saishresphd/POWDER-Load-Balancing.git"
COLLECT_DIR="/tmp/ran_collect"
SCRIPTS_DIR="/tmp/ran_collect/scripts"
SRSRAN_CONF="/etc/srsran"
REPO_LOCAL="/home/saish/POWDER-Load-Balancing"

# ---------------------------------------------------------------------------
# CLI flags
# ---------------------------------------------------------------------------
DRY_RUN=0
SKIP_PULL=0
ONLY_NODE=""

for arg in "$@"; do
  case "$arg" in
    --dry-run)    DRY_RUN=1 ;;
    --skip-pull)  SKIP_PULL=1 ;;
    --node)       shift; ONLY_NODE="$1" ;;
    *)            ;;
  esac
done

[[ "$DRY_RUN" -eq 1 ]] && warn "DRY-RUN mode — no remote changes will be made"

# ---------------------------------------------------------------------------
# SSH helper — returns 0/1; never exits on error
# ---------------------------------------------------------------------------
ssh_run() {
  local node="$1"; shift
  local cmd="$*"
  local host="${NODE_HOST[$node]}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "DRY: ssh ${SSH_USER}@${host} '$cmd'"
    return 0
  fi
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
      -o BatchMode=yes "${SSH_USER}@${host}" "$cmd" 2>&1
}

ssh_ok() {
  local node="$1"; shift
  local cmd="$*"
  ssh_run "$node" "$cmd" >/dev/null 2>&1
  return $?
}

# ---------------------------------------------------------------------------
# Declare result tracking
# ---------------------------------------------------------------------------
declare -A RESULTS   # node -> "PASS" | "WARN" | "FAIL"
FAIL_COUNT=0
WARN_COUNT=0

record() {
  local node="$1" level="$2"
  local cur="${RESULTS[$node]:-PASS}"
  if [[ "$level" == "FAIL" ]]; then
    RESULTS[$node]="FAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  elif [[ "$level" == "WARN" && "$cur" == "PASS" ]]; then
    RESULTS[$node]="WARN"
    WARN_COUNT=$((WARN_COUNT + 1))
  fi
}

# ---------------------------------------------------------------------------
# Deploy function — called for each node
# ---------------------------------------------------------------------------
deploy_node() {
  local node="$1"
  local host="${NODE_HOST[$node]}"
  hdr "Node: $node  ($host)"

  # ── 1. Reachability ────────────────────────────────────────────────────
  if ! ssh_ok "$node" "true"; then
    fail "SSH unreachable — skipping all checks for $node"
    record "$node" "FAIL"
    return
  fi
  ok "SSH reachable"

  # ── 2. Git pull ─────────────────────────────────────────────────────────
  if [[ "$SKIP_PULL" -eq 0 ]]; then
    # Clone if repo does not exist, else pull
    PULL_CMD="
      if [ -d '${REPO_LOCAL}/.git' ]; then
        cd '${REPO_LOCAL}' && git fetch origin && git checkout ${BRANCH} && git pull origin ${BRANCH}
      else
        git clone -b ${BRANCH} ${REPO_URL} '${REPO_LOCAL}'
      fi
    "
    if ssh_run "$node" "$PULL_CMD" 2>&1 | grep -q "error\|fatal"; then
      fail "git pull failed"
      record "$node" "FAIL"
    else
      ok "git pull (branch ${BRANCH})"
    fi
  else
    warn "git pull skipped (--skip-pull)"
  fi

  # ── 3. Create output directory ──────────────────────────────────────────
  if ssh_ok "$node" "mkdir -p '${COLLECT_DIR}/results' '${SCRIPTS_DIR}'"; then
    ok "Output directory ${COLLECT_DIR} ready"
  else
    fail "Could not create ${COLLECT_DIR}"
    record "$node" "FAIL"
  fi

  # ── 4. Sync scripts → /tmp/ran_collect/scripts/ ─────────────────────────
  SYNC_SCRIPTS="
    cp -u '${REPO_LOCAL}/scripts/'*.sh '${SCRIPTS_DIR}/' 2>/dev/null || true
    cp -u '${REPO_LOCAL}/scripts/'*.py '${SCRIPTS_DIR}/' 2>/dev/null || true
    chmod +x '${SCRIPTS_DIR}/'*.sh 2>/dev/null || true
  "
  if ssh_run "$node" "$SYNC_SCRIPTS" >/dev/null 2>&1; then
    ok "Scripts synced to ${SCRIPTS_DIR}"
  else
    warn "Script sync had errors (non-fatal — check manually)"
    record "$node" "WARN"
  fi

  # ── 5. Sync configs → /etc/srsran/ (gNB and UE nodes only) ──────────────
  if [[ "$node" == "gnb1" || "$node" == "gnb2" || "$node" == "uehost1" || "$node" == "uehost2" ]]; then
    CONF_SUBDIR=""
    case "$node" in
      gnb1)    CONF_SUBDIR="gnb1" ;;
      gnb2)    CONF_SUBDIR="gnb2" ;;
      uehost1) CONF_SUBDIR="ues" ;;
      uehost2) CONF_SUBDIR="ues" ;;
    esac
    SYNC_CONF="
      sudo mkdir -p '${SRSRAN_CONF}'
      sudo cp -u '${REPO_LOCAL}/configs/${CONF_SUBDIR}/'*.conf '${SRSRAN_CONF}/' 2>/dev/null || true
    "
    if ssh_run "$node" "$SYNC_CONF" >/dev/null 2>&1; then
      ok "Configs synced to ${SRSRAN_CONF}"
    else
      warn "Config sync had errors — may need sudo perms (check manually)"
      record "$node" "WARN"
    fi
  fi

  # ── 6. Binary prerequisite checks ──────────────────────────────────────
  local required_bins=()
  case "$node" in
    gnb1|gnb2)    required_bins=(srsenb iperf3 perf python3 tc) ;;
    uehost1)      required_bins=(srsue iperf3 python3 ip) ;;
    uehost2)      required_bins=(srsue iperf3 python3 ip) ;;
    core)         required_bins=(python3) ;;
  esac

  for bin in "${required_bins[@]}"; do
    if ssh_ok "$node" "command -v $bin"; then
      ok "binary: $bin"
    else
      fail "MISSING binary: $bin"
      record "$node" "FAIL"
    fi
  done

  # ── 7. Python packages ──────────────────────────────────────────────────
  local required_py=()
  case "$node" in
    gnb1|gnb2)    required_py=(psutil pandas numpy) ;;
    uehost1)      required_py=(pandas numpy) ;;
    uehost2)      required_py=(psutil) ;;
    core)         required_py=() ;;
  esac

  for pkg in "${required_py[@]}"; do
    if ssh_ok "$node" "python3 -c 'import $pkg'"; then
      ok "python3 package: $pkg"
    else
      fail "MISSING python3 package: $pkg  →  run: pip3 install $pkg"
      record "$node" "FAIL"
    fi
  done

  # ── 8. RAPL power interface (gNB nodes only) ────────────────────────────
  if [[ "$node" == "gnb1" || "$node" == "gnb2" ]]; then
    RAPL_PKG="/sys/class/powercap/intel-rapl:0/energy_uj"
    if ssh_ok "$node" "test -r '$RAPL_PKG' || sudo cat '$RAPL_PKG' > /dev/null 2>&1"; then
      ok "RAPL intel-rapl:0 readable"
    else
      fail "RAPL $RAPL_PKG not readable — power collection will fail (try: sudo modprobe intel_rapl_msr)"
      record "$node" "FAIL"
    fi

    # Check DRAM RAPL domain
    RAPL_DRAM="/sys/class/powercap/intel-rapl:0:0/energy_uj"
    if ssh_ok "$node" "test -r '$RAPL_DRAM' || sudo cat '$RAPL_DRAM' > /dev/null 2>&1"; then
      ok "RAPL intel-rapl:0:0 (DRAM) readable"
    else
      warn "RAPL DRAM domain not available — dram power columns will be 0"
      record "$node" "WARN"
    fi
  fi

  # ── 9. perf availability (gNB nodes only) ───────────────────────────────
  if [[ "$node" == "gnb1" || "$node" == "gnb2" ]]; then
    if ssh_ok "$node" "sudo perf stat -e instructions,cycles -a sleep 0.1 2>/dev/null"; then
      ok "perf stat usable (IPC measurement enabled)"
    else
      warn "perf stat unavailable or requires root — IPC column may be 0"
      record "$node" "WARN"
    fi
  fi

  # ── 10. Network namespace check (UE hosts) ──────────────────────────────
  if [[ "$node" == "uehost1" || "$node" == "uehost2" ]]; then
    NS_RANGE=""
    case "$node" in
      uehost1) NS_RANGE="1 5" ;;   # spot-check ue1..ue5
      uehost2) NS_RANGE="51 51" ;;
    esac
    START_UE=$(echo "$NS_RANGE" | cut -d' ' -f1)
    END_UE=$(echo "$NS_RANGE" | cut -d' ' -f2)
    NS_CHECK="
      all_ok=1
      for i in \$(seq $START_UE $END_UE); do
        ip netns list 2>/dev/null | grep -q \"ue\${i}\" || { echo \"MISSING netns ue\${i}\"; all_ok=0; }
      done
      [ \"\$all_ok\" -eq 1 ] && echo OK || echo FAIL
    "
    NS_RESULT=$(ssh_run "$node" "$NS_CHECK")
    if echo "$NS_RESULT" | grep -q "^OK"; then
      ok "Network namespaces ue${START_UE}..ue${END_UE} exist"
    else
      warn "Some UE network namespaces missing: $NS_RESULT"
      warn "  → UEs may not be running yet; namespaces created on srsue attach"
      record "$node" "WARN"
    fi
  fi

  # ── 11. Disk space check (need ≥2 GB for CSV output) ───────────────────
  AVAIL_KB=$(ssh_run "$node" "df -k /tmp | awk 'NR==2{print \$4}'")
  AVAIL_MB=$((${AVAIL_KB:-0} / 1024))
  if [[ "$AVAIL_MB" -ge 2048 ]]; then
    ok "Disk space: ${AVAIL_MB} MB free in /tmp"
  elif [[ "$AVAIL_MB" -ge 512 ]]; then
    warn "Disk space low: ${AVAIL_MB} MB free — experiment may run out; recommend ≥2 GB"
    record "$node" "WARN"
  else
    fail "Disk space critically low: ${AVAIL_MB} MB free — clear /tmp before running"
    record "$node" "FAIL"
  fi

  # ── 12. Existing srsenb / srsue process check ───────────────────────────
  case "$node" in
    gnb1|gnb2)
      if ssh_ok "$node" "pgrep -x srsenb > /dev/null"; then
        ok "srsenb process is running on $node"
      else
        warn "srsenb NOT running on $node — start gNB before launching experiment"
        record "$node" "WARN"
      fi
      ;;
    uehost1)
      UE_COUNT=$(ssh_run "$node" "pgrep -c srsue 2>/dev/null || echo 0")
      if [[ "$UE_COUNT" -ge 50 ]]; then
        ok "srsue processes: $UE_COUNT (≥50 expected)"
      elif [[ "$UE_COUNT" -gt 0 ]]; then
        warn "srsue processes: $UE_COUNT (expected 50 — some UEs may not be attached)"
        record "$node" "WARN"
      else
        warn "No srsue processes found — UEs not running"
        record "$node" "WARN"
      fi
      ;;
    uehost2)
      # UE51 is started by the experiment script itself; warn if already running
      if ssh_ok "$node" "pgrep -x srsue > /dev/null"; then
        warn "srsue already running on uehost2 — may conflict with UE51 startup"
        record "$node" "WARN"
      else
        ok "No stale srsue on uehost2 (clean for UE51 startup)"
      fi
      ;;
  esac

  # ── 13. Write per-node phase file ───────────────────────────────────────
  if ssh_ok "$node" "echo 'deploy_check' > '${COLLECT_DIR}/phase.txt'"; then
    ok "Phase file initialised at ${COLLECT_DIR}/phase.txt"
  else
    warn "Could not write phase.txt (non-fatal)"
    record "$node" "WARN"
  fi

  # ── Final node result ────────────────────────────────────────────────────
  local status="${RESULTS[$node]:-PASS}"
  echo ""
  case "$status" in
    PASS) echo -e "  ${GREEN}>>> $node : ALL CHECKS PASSED ✓${NC}" ;;
    WARN) echo -e "  ${YELLOW}>>> $node : PASSED WITH WARNINGS ⚠${NC}" ;;
    FAIL) echo -e "  ${RED}>>> $node : ONE OR MORE CHECKS FAILED ✗${NC}" ;;
  esac
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo ""
echo "======================================================================"
echo "  POWDER Load-Balancing Experiment — Deploy & Pre-flight Check"
echo "  Branch  : ${BRANCH}"
echo "  Collect : ${COLLECT_DIR}"
echo "  Date    : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "======================================================================"

NODES_TO_DEPLOY=("core" "gnb1" "gnb2" "uehost1" "uehost2")
if [[ -n "$ONLY_NODE" ]]; then
  if [[ -z "${NODE_HOST[$ONLY_NODE]+_}" ]]; then
    echo -e "${RED}ERROR: Unknown node '$ONLY_NODE'. Valid: core gnb1 gnb2 uehost1 uehost2${NC}"
    exit 1
  fi
  NODES_TO_DEPLOY=("$ONLY_NODE")
fi

for node in "${NODES_TO_DEPLOY[@]}"; do
  deploy_node "$node"
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "======================================================================"
echo "  DEPLOYMENT SUMMARY"
echo "======================================================================"
OVERALL="PASS"
for node in "${NODES_TO_DEPLOY[@]}"; do
  status="${RESULTS[$node]:-PASS}"
  case "$status" in
    PASS) echo -e "  ${GREEN}[PASS]${NC}  $node" ;;
    WARN) echo -e "  ${YELLOW}[WARN]${NC}  $node" ; OVERALL="WARN" ;;
    FAIL) echo -e "  ${RED}[FAIL]${NC}  $node" ; OVERALL="FAIL" ;;
  esac
done

echo ""
echo "  Total nodes checked : ${#NODES_TO_DEPLOY[@]}"
echo "  Failures            : $FAIL_COUNT"
echo "  Warnings            : $WARN_COUNT"
echo ""

if [[ "$OVERALL" == "PASS" ]]; then
  echo -e "${GREEN}  ✓  ALL CHECKS PASSED — ready to run:${NC}"
  echo "     bash ${SCRIPTS_DIR}/run_ue51_lb_experiment.sh"
elif [[ "$OVERALL" == "WARN" ]]; then
  echo -e "${YELLOW}  ⚠  WARNINGS PRESENT — review above, then run:${NC}"
  echo "     bash ${SCRIPTS_DIR}/run_ue51_lb_experiment.sh"
else
  echo -e "${RED}  ✗  FAILURES DETECTED — fix issues above before running the experiment${NC}"
  exit 1
fi
echo ""
