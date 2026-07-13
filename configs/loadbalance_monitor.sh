#!/usr/bin/env bash
# =============================================================================
# loadbalance_monitor.sh
#
# PURPOSE
#   Monitor gNB1 after all 10 UEs are attached. When average DL throughput
#   per UE drops below DIP_THRESH_MBPS for DIP_COUNT consecutive poll cycles,
#   trigger handover of UE11 from gNB1 → gNB2.
#
# TRIGGER LOGIC
#   avg_dl = sum of dl_brate across UE1..10 metrics files / 10
#   If avg_dl < DIP_THRESH_MBPS for DIP_COUNT polls  →  migrate UE11 to gNB2
#   (also supports a high-load trigger: avg_dl > HIGH_THRESH_MBPS)
#
# USAGE
#   bash configs/loadbalance_monitor.sh [dip_thresh] [high_thresh] [poll_sec] [dip_count]
#
#   dip_thresh  DL Mbps below which gNB1 is considered "loaded/congested" (default 1.0)
#   high_thresh DL Mbps above which gNB1 is overloaded (default 5.0)
#   poll_sec    Seconds between polls (default 5)
#   dip_count   Consecutive polls needed to trigger (default 3)
#
# NODES
#   core     10.10.1.1  pc811
#   gnb1     10.10.1.2  pc818
#   gnb2     10.10.1.3  pc802
#   uehost1  10.10.1.4  pc808   UE 1-10
#   uehost2  10.10.1.5  pc801   UE 11-20
# =============================================================================

set -euo pipefail

# ── tuneable parameters ──────────────────────────────────────────────────────
DIP_THRESH=${1:-1.0}    # Mbps/UE avg below this = congestion / overload dip
HIGH_THRESH=${2:-5.0}   # Mbps/UE avg above this = high-load overload
POLL_SEC=${3:-5}        # poll interval in seconds
DIP_COUNT=${4:-3}       # consecutive polls to trigger migration

GNB1="saish@pc818.emulab.net"
GNB2="saish@pc802.emulab.net"
UEHOST1="saish@pc808.emulab.net"
UEHOST2="saish@pc801.emulab.net"
CORE="saish@pc811.emulab.net"

SSH="ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5"

LOG_FILE="/tmp/lb_monitor_$(date +%Y%m%d_%H%M%S).log"

# ── helpers ──────────────────────────────────────────────────────────────────
log() {
    local msg="[$(date '+%H:%M:%S')] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

# Read last dl_brate value from a metrics CSV on gnb1
# CSV columns: time;nof_ue;dl_brate;ul_brate;...
get_dl_mbps() {
    local csv_file="$1"
    $SSH "$GNB1" "tail -1 $csv_file 2>/dev/null" | \
        awk -F';' '{if(NF>=3 && $3+0 > 0) printf "%.3f", $3; else print "0"}'
}

# Read nof_ue from a metrics CSV
get_nof_ue() {
    local csv_file="$1"
    $SSH "$GNB1" "tail -1 $csv_file 2>/dev/null" | \
        awk -F';' '{print ($2+0 > 0) ? $2 : "0"}'
}

# Check if a UE netns has an IP (attached)
ue_attached_host1() {
    local ns="ue$1"
    $SSH "$UEHOST1" "sudo ip netns exec $ns ip -br a 2>/dev/null | grep -c tun_" 2>/dev/null | grep -q "^1$"
}

# Get IP of a UE from its netns
ue_ip_host1() {
    local ns="ue$1"
    $SSH "$UEHOST1" "sudo ip netns exec $ns ip -br a 2>/dev/null | grep tun_ | awk '{print \$3}'" 2>/dev/null
}

ue_ip_host2() {
    local ns="ue$1"
    $SSH "$UEHOST2" "sudo ip netns exec $ns ip -br a 2>/dev/null | grep tun_ | awk '{print \$3}'" 2>/dev/null
}

# ── wait for all 10 UEs to be attached ──────────────────────────────────────
wait_for_10_ues() {
    log "Waiting for all 10 UEs (UE1-10) to attach on gNB1..."
    while true; do
        local count=0
        for n in $(seq 1 10); do
            $SSH "$UEHOST1" "sudo ip netns exec ue${n} ip -br a 2>/dev/null | grep -q tun_" 2>/dev/null && \
                count=$((count + 1))
        done
        log "  $count/10 UEs attached"
        if [ "$count" -eq 10 ]; then
            log "✓ All 10 UEs attached. Starting throughput monitor."
            break
        fi
        sleep 10
    done
}

# ── collect current throughput snapshot ─────────────────────────────────────
collect_metrics() {
    local total=0
    local count=0
    local report=""

    for n in $(seq 1 10); do
        local csv="/tmp/gnb1_ue${n}_metrics.csv"
        local dl
        dl=$($SSH "$GNB1" "tail -1 $csv 2>/dev/null | awk -F';' '{printf \"%.3f\", \$3+0}'" 2>/dev/null || echo "0")
        local nue
        nue=$($SSH "$GNB1" "tail -1 $csv 2>/dev/null | awk -F';' '{print \$2+0}'" 2>/dev/null || echo "0")
        report="${report}  UE${n}: ${dl} Mbps (nof_ue=${nue})\n"
        total=$(awk "BEGIN{printf \"%.3f\", $total + $dl}")
        [ "$nue" -gt 0 ] 2>/dev/null && count=$((count + 1)) || true
    done

    LAST_TOTAL_DL=$total
    LAST_ACTIVE_UES=$count
    if [ "$count" -gt 0 ]; then
        LAST_AVG_DL=$(awk "BEGIN{printf \"%.3f\", $total / $count}")
    else
        LAST_AVG_DL="0"
    fi
    LAST_REPORT="$report"
}

# ── start gNB2 instance for UE11 ────────────────────────────────────────────
start_gnb2_ue11() {
    log "Starting gNB2 instance for UE11 (enb_ue1.conf, port 3010, GTP 10.10.1.23)..."
    $SSH "$GNB2" "bash -s" <<'GNBEOF'
mkdir -p /tmp/gnb2_logs
rm -f /tmp/gnb2_logs/ue11_stdout.log
sudo bash -c 'srsenb /etc/srsenb/enb_ue1.conf >> /tmp/gnb2_logs/ue11_stdout.log 2>&1 &'
GNBEOF
    log "Waiting 10s for gNB2 ZMQ REP socket to bind..."
    sleep 10
    $SSH "$GNB2" "ss -tnlp | grep 3010" && log "✓ gNB2 port 3010 LISTENING" || \
        { log "✗ gNB2 failed to start"; return 1; }
}

# ── stop gNB1 UE11 instance ──────────────────────────────────────────────────
stop_gnb1_ue11() {
    log "Stopping gNB1 instance for UE11 (enb_ue11.conf, port 2110)..."
    $SSH "$GNB1" "sudo bash -c 'pkill -f \"srsenb /etc/srsenb/enb_ue11.conf\" 2>/dev/null; true'"
    sleep 3
    $SSH "$GNB1" "ss -tnlp | grep 2110" && \
        log "⚠ port 2110 still up — force kill" && \
        $SSH "$GNB1" "for P in \$(ps aux | grep '[e]nb_ue11' | awk '{print \$2}'); do sudo kill -9 \$P 2>/dev/null; done" || \
        log "✓ port 2110 free"
}

# ── stop UE11 on uehost2 (gNB1 variant) ─────────────────────────────────────
stop_ue11_gnb1() {
    log "Stopping UE11 (pointing at gNB1) on uehost2..."
    $SSH "$UEHOST2" "for P in \$(ps aux | grep '[s]rsue.*ue11' | awk '{print \$2}'); do sudo kill -9 \$P 2>/dev/null; done; sleep 1"
    log "✓ UE11 gNB1-variant stopped"
}

# ── start UE11 on uehost2 pointing at gNB2 ──────────────────────────────────
start_ue11_gnb2() {
    log "Starting UE11 on uehost2 → gNB2 (ue11.conf, rx_port=tcp://10.10.1.3:3010)..."
    $SSH "$UEHOST2" "bash -s" <<'UEEOF'
mkdir -p /tmp/ue_logs
rm -f /tmp/ue_logs/ue11_gnb2_stdout.log
sudo bash -c 'srsue /etc/srsue/ue11.conf >> /tmp/ue_logs/ue11_gnb2_stdout.log 2>&1 &'
UEEOF
    log "Waiting 30s for UE11 to attach on gNB2..."
    sleep 30
    local ip
    ip=$(ue_ip_host2 11)
    if [ -n "$ip" ]; then
        log "✓ UE11 attached on gNB2 — IP: $ip"
        return 0
    else
        log "✗ UE11 not attached yet — check /tmp/ue_logs/ue11_gnb2_stdout.log on pc801"
        # Show last lines of UE11 log for diagnosis
        $SSH "$UEHOST2" "tail -10 /tmp/ue_logs/ue11_gnb2_stdout.log 2>/dev/null" || true
        return 1
    fi
}

# ── verify UE11 ping on gNB2 ─────────────────────────────────────────────────
verify_ue11_ping() {
    log "Pinging core (10.45.0.1) from UE11 netns on gNB2..."
    local result
    result=$($SSH "$UEHOST2" "sudo ip netns exec ue11 ping -c 4 -W 2 10.45.0.1 2>/dev/null | grep -oP '\d+ received'" 2>/dev/null || echo "0 received")
    log "UE11 ping result: $result"
    echo "$result" | grep -q "^[1-9]"
}

# ── print current status table ───────────────────────────────────────────────
print_status() {
    local avg="$1" total="$2" active="$3" dip_cnt="$4" high_cnt="$5"
    echo "┌─────────────────────────────────────────────────────┐"
    echo "│  gNB1 Throughput Monitor — $(date '+%H:%M:%S')              │"
    echo "├─────────────────────────────────────────────────────┤"
    printf "│  Active UEs     : %-4s                              │\n" "$active"
    printf "│  Total DL       : %-8s Mbps                      │\n" "$total"
    printf "│  Avg DL / UE    : %-8s Mbps                      │\n" "$avg"
    printf "│  Dip counter    : %s/%s (thresh < %s Mbps)           │\n" \
        "$dip_cnt" "$DIP_COUNT" "$DIP_THRESH"
    printf "│  High counter   : %s/%s (thresh > %s Mbps)          │\n" \
        "$high_cnt" "$DIP_COUNT" "$HIGH_THRESH"
    echo "└─────────────────────────────────────────────────────┘"
}

# ── main ─────────────────────────────────────────────────────────────────────
main() {
    log "============================================================"
    log "Load-Balance Monitor started"
    log "  Dip  threshold : < ${DIP_THRESH} Mbps/UE for ${DIP_COUNT} polls"
    log "  High threshold : > ${HIGH_THRESH} Mbps/UE for ${DIP_COUNT} polls"
    log "  Poll interval  : ${POLL_SEC}s"
    log "  Log file       : $LOG_FILE"
    log "============================================================"

    # Phase 1: wait until all 10 UEs are up
    wait_for_10_ues

    local dip_counter=0
    local high_counter=0
    local migrated=false

    log "Entering monitoring loop..."

    while true; do
        if $migrated; then
            log "Migration complete. Monitor idle. Ctrl+C to exit."
            # keep running to show UE11 gNB2 status
            sleep 60
            continue
        fi

        # Collect metrics from all 10 UE CSV files on gnb1
        collect_metrics

        # Determine trigger condition
        local trigger=""
        if awk "BEGIN{exit !($LAST_AVG_DL < $DIP_THRESH)}"; then
            dip_counter=$((dip_counter + 1))
            high_counter=0
            trigger="DIP"
        elif awk "BEGIN{exit !($LAST_AVG_DL > $HIGH_THRESH)}"; then
            high_counter=$((high_counter + 1))
            dip_counter=0
            trigger="HIGH"
        else
            dip_counter=0
            high_counter=0
        fi

        print_status "$LAST_AVG_DL" "$LAST_TOTAL_DL" "$LAST_ACTIVE_UES" \
                     "$dip_counter" "$high_counter"

        # Print per-UE breakdown
        echo -e "$LAST_REPORT" | grep -v "^$" | sed 's/^/  /'

        # Check trigger
        local fire=false
        [ "$trigger" = "DIP"  ] && [ "$dip_counter"  -ge "$DIP_COUNT" ]  && fire=true
        [ "$trigger" = "HIGH" ] && [ "$high_counter" -ge "$DIP_COUNT" ]   && fire=true

        if $fire; then
            log ""
            log "══════════════════════════════════════════════════════"
            log "TRIGGER: $trigger — avg DL = ${LAST_AVG_DL} Mbps/UE"
            log "Migrating UE11: gNB1 → gNB2"
            log "══════════════════════════════════════════════════════"

            # Step 1: start gNB2 BEFORE stopping UE11 on gNB1
            if start_gnb2_ue11; then
                # Step 2: stop gNB1's UE11 srsenb instance
                stop_gnb1_ue11
                # Step 3: stop UE11 srsue pointing at gNB1
                stop_ue11_gnb1
                sleep 3
                # Step 4: start UE11 pointing at gNB2
                if start_ue11_gnb2; then
                    verify_ue11_ping && \
                        log "✓ UE11 data plane verified on gNB2" || \
                        log "⚠ UE11 ping not working — check logs"
                fi
            else
                log "✗ gNB2 start failed — aborting migration"
            fi

            log "══════════════════════════════════════════════════════"
            log "Migration sequence complete."
            log "gNB1: UE1–10 | gNB2: UE11 (12–20 add manually or run next step)"
            log "══════════════════════════════════════════════════════"
            migrated=true
        fi

        sleep "$POLL_SEC"
    done
}

# Initialise globals
LAST_TOTAL_DL=0
LAST_ACTIVE_UES=0
LAST_AVG_DL=0
LAST_REPORT=""

main "$@"
