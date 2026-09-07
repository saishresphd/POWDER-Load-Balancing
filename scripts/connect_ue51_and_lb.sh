#!/usr/bin/env bash
# =============================================================================
# connect_ue51_and_lb.sh
#
# 1. Start gNB1's enb_ue51 slot (ZMQ REP on port 40510).
# 2. Start UE51 on uehost2 pointing at gNB1 (port 40511→40510).
# 3. Wait for UE51 to attach (tun_srsue51 UP in netns ue51).
# 4. Trigger load-balance: detach UE51 from gNB1.
# 5. Start gNB2's enb_ue51 slot (ZMQ REP on port 50010).
# 6. Restart UE51 pointing at gNB2 (port 50011→50010).
# 7. Confirm UE51 re-attaches on gNB2.
#
# Run on: uehost1 (pc808, 10.10.1.4) or any node with SSH to all hosts.
# Usage : bash connect_ue51_and_lb.sh [attach_timeout_s] [handover_timeout_s]
#
# Node layout:
#   gnb1    saish@10.10.1.2  (pc818) — ZMQ tx:40510 / rx:40511
#   gnb2    saish@10.10.1.3  (pc802) — ZMQ tx:50010 / rx:50011
#   uehost2 saish@10.10.1.5  (pc801) — runs UE51
# =============================================================================
set -euo pipefail

ATTACH_TIMEOUT_S=${1:-30}
HO_TIMEOUT_S=${2:-60}

GNB1="saish@10.10.1.2"
GNB2="saish@10.10.1.3"
UEHOST2="saish@10.10.1.5"
COLLECT_DIR="/tmp/ran_collect"
CONFIGS_DIR="$COLLECT_DIR/configs"

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ─── Stage UE51 configs to remote nodes ──────────────────────────────────────
log "Staging UE51 configs to uehost2..."
ssh $SSH_OPTS "$UEHOST2" "mkdir -p $CONFIGS_DIR/ues"
scp $SSH_OPTS "$(dirname "$0")/../configs/ues/ue51.conf" \
    "$UEHOST2:$CONFIGS_DIR/ue51_gnb1.conf" 2>/dev/null || \
scp $SSH_OPTS "configs/ues/ue51.conf" \
    "$UEHOST2:$CONFIGS_DIR/ue51_gnb1.conf"
scp $SSH_OPTS "$(dirname "$0")/../configs/ues/ue51_gnb2.conf" \
    "$UEHOST2:$CONFIGS_DIR/ue51_gnb2.conf" 2>/dev/null || \
scp $SSH_OPTS "configs/ues/ue51_gnb2.conf" \
    "$UEHOST2:$CONFIGS_DIR/ue51_gnb2.conf"

log "Staging enb_ue51 conf to gNB1..."
ssh $SSH_OPTS "$GNB1" "mkdir -p $CONFIGS_DIR"
scp $SSH_OPTS "$(dirname "$0")/../configs/gnb1/enb_ue51.conf" \
    "$GNB1:$CONFIGS_DIR/enb_ue51.conf" 2>/dev/null || \
scp $SSH_OPTS "configs/gnb1/enb_ue51.conf" \
    "$GNB1:$CONFIGS_DIR/enb_ue51.conf"

log "Staging enb_ue51 conf to gNB2..."
ssh $SSH_OPTS "$GNB2" "mkdir -p $CONFIGS_DIR"
scp $SSH_OPTS "$(dirname "$0")/../configs/gnb2/enb_ue51.conf" \
    "$GNB2:$CONFIGS_DIR/enb_ue51.conf" 2>/dev/null || \
scp $SSH_OPTS "configs/gnb2/enb_ue51.conf" \
    "$GNB2:$CONFIGS_DIR/enb_ue51.conf"

# ═══════════════════════════════════════════════════
# STEP 1: Start gNB1 enb_ue51 slot
# ═══════════════════════════════════════════════════
log "━━━ Step 1: Starting gNB1 enb_ue51 slot (port 40510) ━━━"

# Kill any stale gNB1-UE51 instance first
ssh $SSH_OPTS "$GNB1" \
    "pkill -f 'srsenb.*enb_ue51' 2>/dev/null || true; sleep 1" || true

ssh $SSH_OPTS "$GNB1" \
    "nohup sudo srsenb $CONFIGS_DIR/enb_ue51.conf \
         >> /tmp/gnb1_ue51_stdout.log 2>&1 </dev/null &
     echo 'gNB1 enb_ue51 started (PID: '\$!')'  "
log "Waiting 8s for gNB1 ZMQ REP socket to bind on port 40510..."
sleep 8

# ═══════════════════════════════════════════════════
# STEP 2: Start UE51 → gNB1
# ═══════════════════════════════════════════════════
log "━━━ Step 2: Starting UE51 on uehost2 → gNB1 ━━━"

# Ensure netns ue51 exists
ssh $SSH_OPTS "$UEHOST2" \
    "sudo ip netns del ue51 2>/dev/null || true; \
     sudo ip netns add ue51 2>/dev/null || true"

# Kill any leftover UE51 process
ssh $SSH_OPTS "$UEHOST2" \
    "pkill -f 'srsue.*ue51' 2>/dev/null || true; sleep 1" || true

UE51_START_TS=$(date '+%s%3N')
ssh $SSH_OPTS "$UEHOST2" \
    "nohup sudo srsue $CONFIGS_DIR/ue51_gnb1.conf \
         >> /tmp/ue51_gnb1_stdout.log 2>&1 </dev/null &
     echo 'UE51 started → gNB1 (PID: '\$!')'  "

# ═══════════════════════════════════════════════════
# STEP 3: Wait for UE51 attach to gNB1
# ═══════════════════════════════════════════════════
log "━━━ Step 3: Waiting for UE51 attach on gNB1 (max ${ATTACH_TIMEOUT_S}s) ━━━"

ATTACHED=0
for i in $(seq 1 "$ATTACH_TIMEOUT_S"); do
    sleep 1
    TUN=$(ssh $SSH_OPTS "$UEHOST2" \
        "ip netns exec ue51 ip link show tun_srsue51 2>/dev/null | grep -c UP || echo 0" \
        2>/dev/null || echo "0")
    if (( TUN >= 1 )); then
        ATTACH_TS=$(date '+%s%3N')
        ATTACHED=1
        ATTACH_LATENCY_MS=$(( ATTACH_TS - UE51_START_TS ))
        log "✓ UE51 attached to gNB1 after ${i}s (latency: ${ATTACH_LATENCY_MS}ms)"
        break
    fi
    log "  [${i}s] waiting for tun_srsue51 UP..."
done

if (( ATTACHED == 0 )); then
    log "WARNING: UE51 did not attach to gNB1 within ${ATTACH_TIMEOUT_S}s — check /tmp/ue51_gnb1_stdout.log on uehost2"
    log "Continuing with load-balance trigger anyway..."
fi

# ═══════════════════════════════════════════════════
# STEP 4: Load-balance trigger — detach UE51 from gNB1
# ═══════════════════════════════════════════════════
log "━━━ Step 4: Load-balance trigger — detaching UE51 from gNB1 ━━━"

LB_TRIGGER_TS=$(date '+%s%3N')
log "LB trigger timestamp: ${LB_TRIGGER_TS}ms"

ssh $SSH_OPTS "$UEHOST2" \
    "pkill -SIGTERM -f 'srsue.*ue51_gnb1' 2>/dev/null || \
     pkill -SIGTERM -f 'srsue.*ue51'      2>/dev/null || true"

DETACH_TS=$(date '+%s%3N')
log "UE51 detach signal sent (${DETACH_TS}ms, +$((DETACH_TS - LB_TRIGGER_TS))ms from trigger)"

# Brief pause for gNB1 RRC release to complete
sleep 3

# ═══════════════════════════════════════════════════
# STEP 5: Start gNB2 enb_ue51 slot
# ═══════════════════════════════════════════════════
log "━━━ Step 5: Starting gNB2 enb_ue51 slot (port 50010) ━━━"

ssh $SSH_OPTS "$GNB2" \
    "pkill -f 'srsenb.*enb_ue51' 2>/dev/null || true; sleep 1" || true

ssh $SSH_OPTS "$GNB2" \
    "nohup sudo srsenb $CONFIGS_DIR/enb_ue51.conf \
         >> /tmp/gnb2_ue51_stdout.log 2>&1 </dev/null &
     echo 'gNB2 enb_ue51 started (PID: '\$!')'  "
log "Waiting 8s for gNB2 ZMQ REP socket to bind on port 50010..."
sleep 8

# ═══════════════════════════════════════════════════
# STEP 6: Restart UE51 → gNB2
# ═══════════════════════════════════════════════════
log "━━━ Step 6: Reconnecting UE51 → gNB2 ━━━"

ssh $SSH_OPTS "$UEHOST2" \
    "sudo ip netns del ue51 2>/dev/null || true; \
     sudo ip netns add ue51 2>/dev/null || true"

RECONNECT_TS=$(date '+%s%3N')
ssh $SSH_OPTS "$UEHOST2" \
    "nohup sudo srsue $CONFIGS_DIR/ue51_gnb2.conf \
         >> /tmp/ue51_gnb2_stdout.log 2>&1 </dev/null &
     echo 'UE51 started → gNB2 (PID: '\$!')'  "

# ═══════════════════════════════════════════════════
# STEP 7: Wait for UE51 re-attach to gNB2
# ═══════════════════════════════════════════════════
log "━━━ Step 7: Waiting for UE51 attach on gNB2 (max ${HO_TIMEOUT_S}s) ━━━"

REATTACHED=0
for i in $(seq 1 "$HO_TIMEOUT_S"); do
    sleep 1
    TUN=$(ssh $SSH_OPTS "$UEHOST2" \
        "ip netns exec ue51 ip link show tun_srsue51 2>/dev/null | grep -c UP || echo 0" \
        2>/dev/null || echo "0")
    if (( TUN >= 1 )); then
        REATTACH_TS=$(date '+%s%3N')
        REATTACHED=1
        HO_DURATION_MS=$(( REATTACH_TS - DETACH_TS ))
        E2E_DURATION_MS=$(( REATTACH_TS - LB_TRIGGER_TS ))
        log "✓ UE51 attached to gNB2 after ${i}s"
        break
    fi
    log "  [${i}s] waiting for tun_srsue51 UP on gNB2..."
done

if (( REATTACHED == 0 )); then
    REATTACH_TS=$(date '+%s%3N')
    HO_DURATION_MS=$(( REATTACH_TS - DETACH_TS ))
    E2E_DURATION_MS=$(( REATTACH_TS - LB_TRIGGER_TS ))
    log "WARNING: UE51 did not confirm attach on gNB2 within ${HO_TIMEOUT_S}s"
    log "  Check: /tmp/ue51_gnb2_stdout.log on uehost2"
    log "  Check: /tmp/gnb2_ue51_stdout.log on gnb2"
fi

# ═══════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════
echo ""
log "══════════════════════════════════════════════════"
log "  UE51 Connect + Load-Balance Summary"
log "══════════════════════════════════════════════════"
log "  UE51 start → gNB1      : ${UE51_START_TS}ms"
log "  UE51 attached gNB1      : $([ $ATTACHED   -eq 1 ] && echo 'YES' || echo 'NO (timeout)')"
log "  LB trigger              : ${LB_TRIGGER_TS}ms"
log "  UE51 detach from gNB1   : ${DETACH_TS}ms"
log "  UE51 reconnect → gNB2   : ${RECONNECT_TS}ms"
log "  UE51 attached gNB2      : $([ $REATTACHED -eq 1 ] && echo 'YES' || echo 'NO (timeout)')"
log "  Handover duration (ms)  : ${HO_DURATION_MS}"
log "  E2E LB duration (ms)    : ${E2E_DURATION_MS}"
log "══════════════════════════════════════════════════"
