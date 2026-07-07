#!/usr/bin/env bash
# =============================================================================
# loadbalance.sh  — UE-11 throughput-triggered handover: gNB1 → gNB2
#
# Logic:
#   1. UE-11 starts attached to gNB1 (port 2110/2111).
#   2. Every POLL_SEC seconds read UE-11's DL throughput from gNB1 metrics CSV.
#   3. If DL Mbps > THRESH_MBPS for TRIGGER_COUNT consecutive polls,
#      declare gNB1 overloaded and migrate UE-11 (and 12-20) to gNB2.
#   4. Kill gNB1 instance for UE-11, wait 5 s, start gNB2 instance for UE-11.
#   5. Kill UE-11, wait 5 s, restart UE-11 pointing at gNB2 (port 3010/3011).
#
# Nodes (POWDER d430, Emulab LAN):
#   core    10.10.1.1  (pc811)
#   gnb1    10.10.1.2  (pc818)
#   gnb2    10.10.1.3  (pc802)
#   uehost1 10.10.1.4  (pc808)   — UE 1-10
#   uehost2 10.10.1.5  (pc801)   — UE 11-20
#
# Usage:  bash loadbalance.sh [threshold_mbps] [poll_sec] [trigger_count]
# =============================================================================

set -euo pipefail

THRESH_MBPS=${1:-5}          # DL Mbps that triggers migration
POLL_SEC=${2:-5}             # poll interval (seconds)
TRIGGER_COUNT=${3:-3}        # consecutive polls above threshold before acting

GNB1="saish@pc818.emulab.net"
GNB2="saish@pc802.emulab.net"
UEHOST1="saish@pc808.emulab.net"
UEHOST2="saish@pc801.emulab.net"

SSH_OPTS="-o StrictHostKeyChecking=no -o BatchMode=yes"

# gNB1 metrics CSV for UE-11 (col 1 = TTI, col 2 = nof_ues, col 11 = dl_brate Mbps)
GNB1_UE11_METRICS="/tmp/gnb1_ue11_metrics.csv"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ─── helpers ──────────────────────────────────────────────────────────────────

get_dl_mbps() {
    # Read last non-empty line of metrics CSV; field 11 = dl_brate (Mbps)
    ssh $SSH_OPTS "$GNB1" "tail -1 $GNB1_UE11_METRICS 2>/dev/null" | \
        awk -F';' '{if(NF>=11) printf "%.2f", $11; else print "0"}'
}

kill_gnb1_ue11() {
    log "Stopping gNB1 instance for UE-11 (port 2110)..."
    ssh $SSH_OPTS "$GNB1" "pkill -f 'srsenb /etc/srsenb/enb_ue11.conf' 2>/dev/null; sleep 2" || true
    log "gNB1-UE11 stopped."
}

kill_ue11_on_uehost2() {
    log "Stopping UE-11 on uehost2..."
    ssh $SSH_OPTS "$UEHOST2" "pkill -f 'srsue /etc/srsue/ue11.conf' 2>/dev/null; sleep 2" || true
    log "UE-11 stopped."
}

start_gnb2_ue11() {
    log "Starting gNB2 instance for UE-11 (port 3010)..."
    ssh $SSH_OPTS "$GNB2" \
        "nohup sudo srsenb /etc/srsenb/enb_ue1.conf \
         >> /tmp/gnb2_ue11_stdout.log 2>&1 &"
    log "gNB2-UE11 started. Waiting 8 s for ZMQ REP socket to bind..."
    sleep 8
}

start_ue11_on_uehost2_gnb2() {
    log "Starting UE-11 pointing at gNB2 (port 3010 on 10.10.1.3)..."
    # ue11.conf already has rx_port=tcp://10.10.1.3:3010 (gNB2)
    ssh $SSH_OPTS "$UEHOST2" \
        "nohup sudo srsue /etc/srsue/ue11.conf \
         >> /tmp/ue11_gnb2_stdout.log 2>&1 &"
    log "UE-11 restarted on gNB2."
}

migrate_ues_12_to_20() {
    log "Migrating UE-12 through UE-20 to gNB2..."
    # Each UE-N (N=12..20) corresponds to gNB2 enb_ue(N-10).conf on pc802
    # and srsue ue${N}.conf on pc801.
    # Kill existing gNB1 instances 12-20 (if any)
    for i in $(seq 2 10); do
        UE_N=$((i + 10))
        log "  Stopping gNB1-UE${UE_N} (if running)..."
        ssh $SSH_OPTS "$GNB1" \
            "pkill -f 'srsenb /etc/srsenb/enb_ue${UE_N}.conf' 2>/dev/null; true" || true
    done
    sleep 3

    # Start gNB2 instances 2-10 (serving UE 12-20)
    for i in $(seq 2 10); do
        UE_N=$((i + 10))
        log "  Starting gNB2 instance for UE-${UE_N} (enb_ue${i}.conf port 30${i}0)..."
        ssh $SSH_OPTS "$GNB2" \
            "nohup sudo srsenb /etc/srsenb/enb_ue${i}.conf \
             >> /tmp/gnb2_ue${UE_N}_stdout.log 2>&1 &"
        sleep 1
    done
    sleep 8   # let all REP sockets bind

    # Restart UE 12-20 on uehost2
    for UE_N in $(seq 12 20); do
        log "  Starting UE-${UE_N} on gNB2..."
        ssh $SSH_OPTS "$UEHOST2" \
            "pkill -f 'srsue /etc/srsue/ue${UE_N}.conf' 2>/dev/null; sleep 1; \
             nohup sudo srsue /etc/srsue/ue${UE_N}.conf \
             >> /tmp/ue${UE_N}_gnb2_stdout.log 2>&1 &"
        sleep 2
    done
    log "UE 12-20 migration complete."
}

verify_ue11_gnb2() {
    log "Verifying UE-11 attachment on gNB2..."
    sleep 15
    ATTACHED=$(ssh $SSH_OPTS "$UEHOST2" \
        "ip netns exec ue11 ip addr show 2>/dev/null | grep 'inet 10\.45\.' | awk '{print \$2}'" 2>/dev/null || true)
    if [ -n "$ATTACHED" ]; then
        log "✓ UE-11 attached on gNB2. IP: $ATTACHED"
        return 0
    else
        log "✗ UE-11 NOT attached on gNB2 yet. Check /tmp/ue11_gnb2_stdout.log on pc801."
        return 1
    fi
}

# ─── main polling loop ────────────────────────────────────────────────────────

log "Load balancer started."
log "Threshold: ${THRESH_MBPS} Mbps | Poll: ${POLL_SEC}s | Trigger count: ${TRIGGER_COUNT}"
log "Monitoring UE-11 throughput on gNB1 (metrics: $GNB1_UE11_METRICS)..."

consecutive=0
migrated=false

while true; do
    if $migrated; then
        log "Migration complete. Load balancer idle."
        break
    fi

    DL=$(get_dl_mbps)
    log "UE-11 DL throughput on gNB1: ${DL} Mbps (threshold: ${THRESH_MBPS}, count: ${consecutive}/${TRIGGER_COUNT})"

    if awk -v dl="$DL" -v thr="$THRESH_MBPS" 'BEGIN{exit !(dl+0 > thr+0)}'; then
        consecutive=$((consecutive + 1))
        log "  → Above threshold (${consecutive}/${TRIGGER_COUNT})"
    else
        if [ $consecutive -gt 0 ]; then
            log "  → Below threshold, resetting counter."
        fi
        consecutive=0
    fi

    if [ $consecutive -ge $TRIGGER_COUNT ]; then
        log ""
        log "═══════════════════════════════════════════════════"
        log "TRIGGER: gNB1 UE-11 DL > ${THRESH_MBPS} Mbps for ${TRIGGER_COUNT} polls."
        log "Starting migration: UE-11 → gNB2, then UE-12..20 → gNB2"
        log "═══════════════════════════════════════════════════"

        kill_gnb1_ue11
        sleep 3
        start_gnb2_ue11
        kill_ue11_on_uehost2
        sleep 3
        start_ue11_on_uehost2_gnb2
        verify_ue11_gnb2 || true

        log "Migrating remaining UEs 12-20..."
        migrate_ues_12_to_20

        migrated=true
        log "═══════════════════════════════════════════════════"
        log "Load balancing complete. UE 11-20 now on gNB2."
        log "═══════════════════════════════════════════════════"
    fi

    sleep $POLL_SEC
done
