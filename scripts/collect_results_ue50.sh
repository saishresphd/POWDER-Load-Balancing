#!/bin/bash
# =============================================================================
# collect_results_ue50.sh
#
# PURPOSE:
#   Download all experiment data from all POWDER nodes to local machine
#   after running:
#     1. experiment_ue50_gnb1_ramp.sh
#     2. loadbalance_ue50_to_gnb2.sh
#
# Downloads to: ./results/ue50_experiment_<timestamp>/
# =============================================================================

set -euo pipefail

USER_ARG="${1:-saish}"
CORE="saish@pc811.emulab.net"
GNB1="saish@pc818.emulab.net"
GNB2="saish@pc802.emulab.net"
UEHOST1="saish@pc808.emulab.net"

TS=$(date +%Y%m%d_%H%M%S)
LOCAL_DIR="./results/ue50_experiment_${TS}"
mkdir -p "$LOCAL_DIR"/{gnb1_ramp,lb_transition,gnb2_post,mme_logs}

log() { echo "[$(date +%H:%M:%S)] $*"; }

log "=== Collecting UE50 experiment results to $LOCAL_DIR ==="

# ── gNB1 ramp data ───────────────────────────────────────────────────────────
log "Downloading gnb1 ramp data..."
rsync -avz --ignore-missing-args \
    "${GNB1}:/tmp/ran_collect/ue50_gnb1/" \
    "$LOCAL_DIR/gnb1_ramp/" || log "WARN: partial gnb1 ramp data"

# ── Load-balance transition data ──────────────────────────────────────────────
log "Downloading LB transition data from gnb1..."
rsync -avz --ignore-missing-args \
    "${GNB1}:/tmp/ran_collect/ue50_lb_transition/" \
    "$LOCAL_DIR/lb_transition/gnb1/" || true

log "Downloading LB transition data from gnb2..."
rsync -avz --ignore-missing-args \
    "${GNB2}:/tmp/ran_collect/ue50_lb_transition/" \
    "$LOCAL_DIR/lb_transition/gnb2/" || true

# ── gnb2 post-handover data ───────────────────────────────────────────────────
log "Downloading gnb2 post-HO data..."
rsync -avz --ignore-missing-args \
    "${GNB2}:/tmp/ran_collect/ue50_gnb2/" \
    "$LOCAL_DIR/gnb2_post/" || log "WARN: partial gnb2 data"

# ── uehost1 data ──────────────────────────────────────────────────────────────
log "Downloading uehost1 data..."
rsync -avz --ignore-missing-args \
    "${UEHOST1}:/tmp/ran_collect/" \
    "$LOCAL_DIR/uehost1/" || true

# ── MME logs (core) ───────────────────────────────────────────────────────────
log "Downloading MME log excerpt from core..."
ssh "$CORE" "sudo grep -E \
    'Attach complete|Attach request|eNB-S1|Number of eNBs|Number of MME-UEs' \
    /var/log/open5gs/mme.log 2>/dev/null | tail -200" \
    > "$LOCAL_DIR/mme_logs/mme_attach_events.txt" || true

ssh "$CORE" "sudo tail -500 /var/log/open5gs/mme.log" \
    > "$LOCAL_DIR/mme_logs/mme_tail_500.txt" || true

# ── Handover timing file ──────────────────────────────────────────────────────
log "Copying handover timing..."
rsync -avz --ignore-missing-args \
    "${GNB1}:/tmp/ran_collect/ue50_lb_transition/handover_timing.txt" \
    "$LOCAL_DIR/lb_transition/handover_timing.txt" || \
rsync -avz --ignore-missing-args \
    "${GNB2}:/tmp/ran_collect/ue50_lb_transition/handover_timing.txt" \
    "$LOCAL_DIR/lb_transition/handover_timing.txt" || \
    log "WARN: handover_timing.txt not found"

# ── Print summary of downloaded files ────────────────────────────────────────
log "=== Downloaded file summary ==="
find "$LOCAL_DIR" -type f | sort | while read f; do
    SIZE=$(wc -c < "$f" 2>/dev/null || echo "?")
    echo "  $f  (${SIZE}B)"
done

log "=== All data in: $LOCAL_DIR ==="
log "Next step: python3 scripts/build_master_ue50.py $LOCAL_DIR"
