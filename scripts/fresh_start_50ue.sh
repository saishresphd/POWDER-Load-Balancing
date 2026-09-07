#!/bin/bash
# fresh_start_50ue.sh
# Complete fresh connection: kill everything, restart MME, start all 50 srsenb
# slots on gNB1, then attach all 50 srsue on uehost1.
#
# Run from local machine: bash scripts/fresh_start_50ue.sh
# Nodes: core=pc811, gnb1=pc818, uehost1=pc808

set -euo pipefail

CORE="saish@pc811.emulab.net"
GNB1="saish@pc818.emulab.net"
UEHOST1="saish@pc808.emulab.net"
PROJ="/proj/ATLANTIC-eVISION/exp/loadbalance/tmp/ran_9ue_lb"

log() { echo "[$(date +%H:%M:%S)] $*"; }

# ── STEP 1: Kill all srsue on uehost1 ────────────────────────────────────────
log "STEP 1: Kill all srsue on uehost1"
ssh "$UEHOST1" "bash -s" <<'EOF'
sudo killall srsue 2>/dev/null || true
sleep 2
echo "  srsue remaining: $(ps aux | grep srsue | grep -v grep | wc -l)"
EOF

# ── STEP 2: Kill all srsenb on gNB1 ──────────────────────────────────────────
log "STEP 2: Kill all srsenb on gNB1"
ssh "$GNB1" "bash -s" <<'EOF'
sudo killall srsenb 2>/dev/null || true
sleep 3
# Force-kill any stragglers
for PID in $(ps aux | grep "[s]rsenb" | awk '{print $2}'); do
    sudo kill -9 "$PID" 2>/dev/null || true
done
sleep 2
echo "  srsenb remaining: $(ps aux | grep srsenb | grep -v grep | wc -l)"
EOF

# ── STEP 3: Restart Open5GS MME (and SGW) for clean UE/eNB context ───────────
log "STEP 3: Restart Open5GS MME + SGW on core"
ssh "$CORE" "bash -s" <<'EOF'
sudo systemctl restart open5gs-mmed
sudo systemctl restart open5gs-sgwcd
sudo systemctl restart open5gs-sgwud
sleep 5
echo "  mmed:  $(sudo systemctl is-active open5gs-mmed)"
echo "  sgwcd: $(sudo systemctl is-active open5gs-sgwcd)"
echo "  sgwud: $(sudo systemctl is-active open5gs-sgwud)"
EOF

# ── STEP 4: Start all 50 srsenb slots on gNB1 ────────────────────────────────
log "STEP 4: Start srsenb ue1-50 on gNB1 (1s stagger)"
ssh "$GNB1" "bash -s" <<'EOF'
mkdir -p /tmp/gnb1_logs
for i in $(seq 1 50); do
    LOG="/tmp/gnb1_logs/ue${i}_stdout.log"
    > "$LOG"
    sudo bash -c "srsenb /etc/srsenb/enb_ue${i}.conf >> $LOG 2>&1 &"
    echo "  Started enb_ue${i}"
    sleep 1
done

echo ""
echo "  Waiting 25s for all slots to register with MME..."
sleep 25

echo "  srsenb count: $(ps aux | grep '[s]rsenb' | grep -v grep | wc -l) (expect 100)"
# Spot-check ZMQ ports for ue1, ue25, ue50
for PORT in 40010 40250 40500; do
    STATUS=$(ss -tnlp 2>/dev/null | grep ":${PORT} " | head -1)
    if [ -n "$STATUS" ]; then
        echo "  port $PORT: LISTEN ✓"
    else
        echo "  port $PORT: NOT listening ✗"
    fi
done
EOF

# ── STEP 5: Verify MME has 50 eNBs ───────────────────────────────────────────
log "STEP 5: Verify MME eNB count"
ssh "$CORE" "sudo journalctl -u open5gs-mmed --no-pager -n 5" 2>/dev/null | grep "Number of eNBs" | tail -3

# ── STEP 6: Attach UE1-50 on uehost1 using attach_50ue_fast.sh ───────────────
log "STEP 6: Attach UE1-50 on uehost1"
ssh "$UEHOST1" "bash -s" <<'EOF'
mkdir -p /tmp/ran_collect /tmp/ue_logs
SCRIPT="/proj/ATLANTIC-eVISION/exp/loadbalance/tmp/ran_9ue_lb/scripts/attach_50ue_fast.sh"
nohup bash "$SCRIPT" 1 50 35 > /tmp/ran_collect/attach_50ue_run.log 2>&1 </dev/null &
echo "  attach_50ue_fast.sh PID=$! — logs at /tmp/ran_collect/attach_50ue_run.log"
EOF

log "Attach script running in background. Polling progress every 60s..."

# ── STEP 7: Poll until done ───────────────────────────────────────────────────
for POLL in $(seq 1 40); do
    sleep 60
    RESULT=$(ssh "$UEHOST1" "cat /tmp/ran_collect/attach_50ue_run.log 2>/dev/null | tail -5")
    ATTACHED=$(ssh "$UEHOST1" "grep -c ATTACHED /tmp/ran_collect/attach_50ue_run.log 2>/dev/null || echo 0")
    FAILED=$(ssh "$UEHOST1" "grep -c FAILED /tmp/ran_collect/attach_50ue_run.log 2>/dev/null || echo 0")
    log "  Poll $POLL — attached=$ATTACHED failed=$FAILED"
    echo "$RESULT"
    # Done when attach script prints the DONE line
    if echo "$RESULT" | grep -q "DONE:"; then
        break
    fi
done

# ── STEP 8: Final summary ─────────────────────────────────────────────────────
log "=== Final attach summary ==="
ssh "$UEHOST1" "grep -E 'DONE|ATTACHED|FAILED' /tmp/ran_collect/attach_50ue_run.log 2>/dev/null | tail -5"

ATTACHED_FINAL=$(ssh "$UEHOST1" "grep -c ATTACHED /tmp/ran_collect/attach_50ue_run.log 2>/dev/null || echo 0")
log "Total attached: $ATTACHED_FINAL / 50"

if [ "$ATTACHED_FINAL" -ge 49 ]; then
    log "✓ 50 UEs connected on gNB1 — ready for LB experiment"
else
    log "⚠ Only $ATTACHED_FINAL UEs attached — check /tmp/ran_collect/attach_log.csv on uehost1"
fi
