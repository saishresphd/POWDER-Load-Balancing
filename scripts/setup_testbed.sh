#!/usr/bin/env bash
# setup_testbed.sh — One-shot POWDER node preparation for LB experiment
# Run once from the master (core node or local machine) before any experiment.
# Requirements: SSH key-based access to all 5 nodes is already configured.
# Usage: bash scripts/setup_testbed.sh
set -euo pipefail

###############################################################################
# Configuration
###############################################################################
REPO_DIR="${REPO_DIR:-$HOME/POWDER-Load-Balancing}"
COLLECT_DIR="/tmp/ran_collect"

CORE="saish@pc811.emulab.net"
GNB1="saish@pc818.emulab.net"
GNB2="saish@pc802.emulab.net"
UEHOST1="saish@pc808.emulab.net"
UEHOST2="saish@pc801.emulab.net"

SSH="ssh -o StrictHostKeyChecking=no -o BatchMode=yes"
SCP="scp -o StrictHostKeyChecking=no"

ALL_NODES=("$CORE" "$GNB1" "$GNB2" "$UEHOST1" "$UEHOST2")
NODE_NAMES=("core" "gnb1" "gnb2" "uehost1" "uehost2")

###############################################################################
# Helpers
###############################################################################
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
phase(){ echo; echo "====== $1 ======"; }

###############################################################################
# PHASE 1: Install kernel perf tools + enable RAPL on every node
###############################################################################
phase "KERNEL_TOOLS"
for node in "${ALL_NODES[@]}"; do
    log "Configuring $node ..."
    $SSH "$node" bash << 'REMOTE'
set -euo pipefail
KVER=$(uname -r)

# Install linux-tools for perf stat
if ! command -v perf &>/dev/null; then
    apt-get install -y -q linux-tools-"$KVER" linux-tools-common 2>/dev/null || \
    apt-get install -y -q linux-tools-generic 2>/dev/null || \
    echo "WARN: perf install skipped (try manually)"
fi

# Lower perf paranoia so non-root can sample
sysctl -w kernel.perf_event_paranoid=1 2>/dev/null || true

# Load RAPL kernel modules for Intel power measurement
modprobe intel_rapl_common 2>/dev/null || modprobe intel_rapl 2>/dev/null || true
modprobe intel_rapl_msr    2>/dev/null || true

# Make RAPL energy counter world-readable
for rapl_path in /sys/class/powercap/intel-rapl/*/energy_uj \
                 /sys/class/powercap/intel-rapl:*/energy_uj; do
    [ -f "$rapl_path" ] && chmod o+r "$rapl_path" 2>/dev/null || true
done

# Install Python3 + psutil for deep_sysmon.py
python3 -c "import psutil" 2>/dev/null || \
    pip3 install -q psutil 2>/dev/null || \
    apt-get install -y -q python3-psutil 2>/dev/null || true

echo "Node kernel setup done: $(hostname)"
REMOTE
done
log "Kernel tools phase complete."

###############################################################################
# PHASE 2: Create collect directories on every node
###############################################################################
phase "COLLECT_DIRS"
for node in "${ALL_NODES[@]}"; do
    $SSH "$node" "mkdir -p $COLLECT_DIR && chmod 777 $COLLECT_DIR"
    log "  $node: $COLLECT_DIR created"
done

###############################################################################
# PHASE 3: Copy scripts and configs to every node
###############################################################################
phase "DEPLOY_SCRIPTS"
for node in "${ALL_NODES[@]}"; do
    log "Deploying scripts to $node ..."
    # Copy scripts
    $SCP "$REPO_DIR/scripts/"*.sh "$node:$COLLECT_DIR/" 2>/dev/null || true
    $SCP "$REPO_DIR/scripts/"*.py "$node:$COLLECT_DIR/" 2>/dev/null || true
    # Copy configs
    $SSH "$node" "mkdir -p $COLLECT_DIR/configs"
    $SCP -r "$REPO_DIR/configs" "$node:$COLLECT_DIR/" 2>/dev/null || true
    # Make scripts executable
    $SSH "$node" "chmod +x $COLLECT_DIR/*.sh 2>/dev/null || true"
    log "  $node: scripts deployed"
done

###############################################################################
# PHASE 4: Create gnb_metrics symlinks (needed by collect_ue51_handover.sh)
###############################################################################
phase "GNB_METRICS_SYMLINKS"
# gNB1: gnb_metrics.csv written by collect_gnb_metrics.sh running on gnb1
$SSH "$GNB1" "touch $COLLECT_DIR/gnb_metrics.csv ; \
              ln -sf $COLLECT_DIR/gnb_metrics.csv $COLLECT_DIR/gnb_metrics_raw_gnb1.csv ; \
              echo 'gnb1 symlink OK'"

# gNB2: gnb_metrics.csv written by collect_gnb_metrics.sh running on gnb2
$SSH "$GNB2" "touch $COLLECT_DIR/gnb_metrics.csv ; \
              ln -sf $COLLECT_DIR/gnb_metrics.csv $COLLECT_DIR/gnb_metrics_raw_gnb2.csv ; \
              echo 'gnb2 symlink OK'"

###############################################################################
# PHASE 5: Verify perf + RAPL on gNB nodes (most critical for research data)
###############################################################################
phase "VERIFY_GNB_CAPABILITIES"
for node in "$GNB1" "$GNB2"; do
    log "Verifying $node ..."
    $SSH "$node" bash << 'REMOTE'
echo "  hostname: $(hostname)"
echo "  kernel:   $(uname -r)"
# perf
if command -v perf &>/dev/null; then
    echo "  perf:     OK ($(perf --version 2>&1 | head -1))"
else
    echo "  perf:     MISSING — install linux-tools-$(uname -r)"
fi
# RAPL
RAPL_PATH=$(ls /sys/class/powercap/intel-rapl/intel-rapl:0/energy_uj 2>/dev/null || \
            ls /sys/class/powercap/intel-rapl:0/energy_uj 2>/dev/null || echo "")
if [ -n "$RAPL_PATH" ]; then
    READABLE=$(cat "$RAPL_PATH" 2>/dev/null && echo "READABLE" || echo "NOT_READABLE")
    echo "  RAPL:     $RAPL_PATH [$READABLE]"
else
    echo "  RAPL:     NOT FOUND — modprobe intel_rapl_common failed"
fi
# psutil
python3 -c "import psutil; print('  psutil:   OK v' + psutil.__version__)" 2>/dev/null || \
    echo "  psutil:   MISSING — pip3 install psutil"
# collect dir
echo "  $COLLECT_DIR exists: $(ls -d /tmp/ran_collect 2>/dev/null && echo YES || echo NO)"
REMOTE
done

###############################################################################
# PHASE 6: Summary
###############################################################################
phase "SETUP_COMPLETE"
cat << 'EOF'
Testbed setup finished. Next steps:
  1. Ensure 50 UEs are attached to gNB1 (run your existing 50-UE launch)
  2. Run the master experiment:
       bash scripts/master_lb_experiment.sh
  3. After experiment, retrieve logs:
       bash scripts/collect_results.sh   # (or scp /tmp/ran_collect/ from each node)
  4. Analyse results:
       python3 scripts/analyze_lb_results.py --results-dir ./results

Key data directories on each node:
  /tmp/ran_collect/system_metrics_<node>.log    CPU/mem/net (5s)
  /tmp/ran_collect/gnb_metrics.csv              Per-UE gNB stats (5s)
  /tmp/ran_collect/power_<node>.log             RAPL pkg+DRAM (1s)
  /tmp/ran_collect/deep_sysmon_<node>.csv       Per-core+process (2s)
  /tmp/ran_collect/perf_ipc_<node>.log          IPC/cycles/instr (10s)
  /tmp/ran_collect/ue51_handover.csv            Handover event timeline
EOF
