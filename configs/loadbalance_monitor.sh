#!/usr/bin/env bash
# =============================================================================
# loadbalance_monitor.sh
#
# PURPOSE
#   Monitor gNB1 after all 110 UEs are attached.  Detect two overload
#   conditions and migrate UE101–110 from gNB1 → gNB2 one by one:
#
#   1. THROUGHPUT trigger  — avg DL per UE across UE1–100 drops below
#                            DIP_THRESH_MBPS for DIP_COUNT consecutive polls
#                            (indicates gNB1 is congested)
#
#   2. CPU trigger         — gNB1 CPU utilisation exceeds CPU_THRESH_PCT
#                            for CPU_COUNT consecutive polls
#                            (power-saving / overload protection)
#
# MIGRATION BEHAVIOUR
#   When either trigger fires, UE101–110 are migrated to gNB2 one at a time:
#     a) Start gNB2 slot for UEi  (srsenb enb_ueN.conf on pc802)
#     b) Stop  gNB1 slot for UEi
#     c) Stop  UEi srsue process on uehost2 (was using _gnb1.conf)
#     d) Start UEi srsue on uehost2 pointing at gNB2 (ue{i}.conf)
#     e) Verify attach + ping before moving to next UE
#
# USAGE
#   bash configs/loadbalance_monitor.sh [dip_thresh] [cpu_thresh] [poll_sec] [dip_count] [cpu_count]
#
#   dip_thresh  Avg DL Mbps/UE below which gNB1 is considered congested (default 0.5)
#   cpu_thresh  gNB1 CPU% above which power-saving handover triggers     (default 80)
#   poll_sec    Seconds between polls                                     (default 5)
#   dip_count   Consecutive dip polls needed to trigger                  (default 3)
#   cpu_count   Consecutive CPU polls needed to trigger                   (default 3)
#
# NODES
#   core     pc811  10.10.1.1
#   gnb1     pc818  10.10.1.2   UE1–100 base  +  UE101–110 LB (initial)
#   gnb2     pc802  10.10.1.3   UE101–110 LB targets
#   uehost1  pc808  10.10.1.4   UE1–100
#   uehost2  pc801  10.10.1.5   UE101–110
# =============================================================================
set -euo pipefail

# ── Tuneable parameters ───────────────────────────────────────────────────────
DIP_THRESH=${1:-0.5}    # Mbps/UE avg — below this = throughput dip trigger
CPU_THRESH=${2:-80}     # gNB1 CPU %  — above this = CPU overload trigger
POLL_SEC=${3:-5}        # poll interval in seconds
DIP_COUNT=${4:-3}       # consecutive throughput-dip polls to trigger
CPU_COUNT=${5:-3}       # consecutive CPU-overload polls to trigger

GNB1="saish@pc818.emulab.net"
GNB2="saish@pc802.emulab.net"
UEHOST2="saish@pc801.emulab.net"
UEHOST1="saish@pc808.emulab.net"

SSH="ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5"
LOG_FILE="/tmp/lb_monitor_$(date +%Y%m%d_%H%M%S).log"

# ── Globals ───────────────────────────────────────────────────────────────────
LAST_AVG_DL=0
LAST_TOTAL_DL=0
LAST_ACTIVE_UES=0
LAST_CPU=0
MIGRATED_COUNT=0    # how many of UE101-110 have been moved to gNB2

# ── Helpers ───────────────────────────────────────────────────────────────────
log() {
    local msg="[$(date '+%H:%M:%S')] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

# Collect avg DL Mbps across UE1–100 metrics CSVs on gNB1
# CSV format: time;nof_ue;dl_brate;ul_brate;...
collect_metrics() {
    local total=0 active=0

    for n in $(seq 1 100); do
        local csv="/tmp/gnb1_ue${n}_metrics.csv"
        local row
        row=$($SSH "$GNB1" "tail -1 '$csv' 2>/dev/null" 2>/dev/null || echo "")
        local dl nue
        dl=$(echo "$row"  | awk -F';' '{printf "%.4f", $3+0}')
        nue=$(echo "$row" | awk -F';' '{print ($2+0 > 0) ? $2 : 0}')
        total=$(awk "BEGIN{printf \"%.4f\", $total + $dl}")
        [ "${nue:-0}" -gt 0 ] 2>/dev/null && active=$((active + 1)) || true
    done

    LAST_TOTAL_DL=$total
    LAST_ACTIVE_UES=$active
    if [ "$active" -gt 0 ]; then
        LAST_AVG_DL=$(awk "BEGIN{printf \"%.4f\", $total / $active}")
    else
        LAST_AVG_DL=0
    fi
}

# Read gNB1 CPU utilisation (1-min load average as % of a single core)
collect_cpu() {
    local load
    load=$($SSH "$GNB1" "cat /proc/loadavg 2>/dev/null | awk '{print \$1}'" 2>/dev/null || echo "0")
    local cores
    cores=$($SSH "$GNB1" "nproc 2>/dev/null" 2>/dev/null || echo "1")
    LAST_CPU=$(awk "BEGIN{printf \"%.1f\", ($load / $cores) * 100}")
}

# Check if UEi netns on uehost2 has a tun IP (attached)
ue_attached_uh2() {
    local i=$1
    $SSH "$UEHOST2" "sudo ip netns exec ue${i} ip -br a 2>/dev/null | grep -q tun_" 2>/dev/null
}

ue_ip_uh2() {
    local i=$1
    $SSH "$UEHOST2" "sudo ip netns exec ue${i} ip -br a 2>/dev/null | grep tun_ | awk '{print \$3}'" 2>/dev/null
}

# ── Wait for all 100 base UEs to attach on gNB1 ───────────────────────────────
wait_for_base_ues() {
    log "Waiting for UE1–100 to attach on gNB1..."
    while true; do
        local count=0
        for n in $(seq 1 100); do
            $SSH "$UEHOST1" "sudo ip netns exec ue${n} ip -br a 2>/dev/null | grep -q tun_" 2>/dev/null && \
                count=$((count + 1)) || true
        done
        log "  ${count}/100 base UEs attached"
        [ "$count" -ge 100 ] && break
        sleep 15
    done
    log "✓ All 100 base UEs attached.  Starting throughput + CPU monitor."
}

# ── Migrate a single LB UE (i = 101..110) gNB1 → gNB2 ───────────────────────
migrate_ue() {
    local i=$1
    local j=$((i - 100))   # slot index 1–10
    log "  → Migrating UE${i} (slot j=${j}): gNB1 → gNB2"

    # Step 1: start gNB2 slot BEFORE stopping gNB1 slot (ZMQ REP must bind first)
    log "    [1/4] Starting gNB2 slot enb_ue${i}.conf (port 6${j:?}JJ0, GTP .21${j})"
    $SSH "$GNB2" "sudo bash -c 'mkdir -p /tmp/gnb2_logs; srsenb /etc/srsenb/enb_ue${i}.conf >> /tmp/gnb2_logs/ue${i}_stdout.log 2>&1 &'"
    sleep 10
    local gnb2_port
    gnb2_port=$(printf "6%03d0" "$j")
    $SSH "$GNB2" "ss -tnlp | grep -q ${gnb2_port}" && \
        log "    ✓ gNB2 port ${gnb2_port} LISTENING" || \
        { log "    ✗ gNB2 port ${gnb2_port} not up — aborting UE${i} migration"; return 1; }

    # Step 2: stop gNB1 slot for this UE
    log "    [2/4] Stopping gNB1 slot enb_ue${i}.conf"
    $SSH "$GNB1" "for P in \$(ps aux | grep '[e]nb_ue${i}.conf' | awk '{print \$2}'); do sudo kill -9 \$P 2>/dev/null; done; sleep 2"

    # Step 3: stop UE process on uehost2 (was using _gnb1.conf)
    log "    [3/4] Stopping UE${i} srsue on uehost2 (gnb1 variant)"
    $SSH "$UEHOST2" "for P in \$(ps aux | grep '[s]rsue.*ue${i}_gnb1' | awk '{print \$2}'); do sudo kill -9 \$P 2>/dev/null; done; sleep 2"
    $SSH "$UEHOST2" "sudo ip netns exec ue${i} ip link del tun_srsue${i} 2>/dev/null || true"

    # Step 4: start UE on gNB2 variant
    log "    [4/4] Starting UE${i} on uehost2 → gNB2 (ue${i}.conf)"
    $SSH "$UEHOST2" "sudo bash -c 'mkdir -p /tmp/ue_logs; srsue /etc/srsue/ue${i}.conf >> /tmp/ue_logs/ue${i}_gnb2_stdout.log 2>&1 &'"
    sleep 30
    if ue_attached_uh2 "$i"; then
        local ip
        ip=$(ue_ip_uh2 "$i")
        # verify ping to core
        local ping_ok
        ping_ok=$($SSH "$UEHOST2" "sudo ip netns exec ue${i} ping -c 3 -W 2 10.45.0.1 2>/dev/null | grep -oP '\d+ received'" 2>/dev/null || echo "0 received")
        if echo "$ping_ok" | grep -q "^[1-9]"; then
            log "    ✓ UE${i} migrated — IP: ${ip}  ping: ${ping_ok}"
        else
            log "    ⚠ UE${i} attached (${ip}) but ping failed — check /tmp/ue_logs/ue${i}_gnb2_stdout.log"
        fi
    else
        log "    ✗ UE${i} not attached on gNB2 — check logs"
        return 1
    fi
}

# ── Print status table ────────────────────────────────────────────────────────
print_status() {
    local dip_cnt=$1 cpu_cnt=$2 trigger=$3
    printf "\n┌──────────────────────────────────────────────────────────┐\n"
    printf "│  gNB1 Monitor — %-42s│\n" "$(date '+%H:%M:%S')"
    printf "├──────────────────────────────────────────────────────────┤\n"
    printf "│  Base UEs active : %-4s / 100                            │\n" "$LAST_ACTIVE_UES"
    printf "│  Total DL        : %-8s Mbps                          │\n" "$LAST_TOTAL_DL"
    printf "│  Avg DL / UE     : %-8s Mbps  (thresh < %s)          │\n" "$LAST_AVG_DL" "$DIP_THRESH"
    printf "│  gNB1 CPU load   : %-6s %%  (thresh > %s%%)            │\n" "$LAST_CPU" "$CPU_THRESH"
    printf "│  Dip  counter    : %s/%s                                  │\n" "$dip_cnt" "$DIP_COUNT"
    printf "│  CPU  counter    : %s/%s                                  │\n" "$cpu_cnt" "$CPU_COUNT"
    printf "│  LB migrated     : %s/10 UEs moved to gNB2               │\n" "$MIGRATED_COUNT"
    printf "│  Trigger         : %-10s                               │\n" "${trigger:-none}"
    printf "└──────────────────────────────────────────────────────────┘\n"
}

# ── Main loop ─────────────────────────────────────────────────────────────────
main() {
    log "============================================================"
    log "Load-Balance Monitor started"
    log "  Throughput dip  : avg DL < ${DIP_THRESH} Mbps/UE for ${DIP_COUNT} polls"
    log "  CPU overload    : gNB1 CPU > ${CPU_THRESH}% for ${CPU_COUNT} polls"
    log "  Poll interval   : ${POLL_SEC}s"
    log "  Log             : $LOG_FILE"
    log "  LB UEs          : UE101–110 (uehost2 → gNB1 initially → gNB2 on trigger)"
    log "============================================================"

    wait_for_base_ues

    local dip_counter=0
    local cpu_counter=0
    # LB UE list: 101..110 — we work through them in order
    local -a lb_ues=(101 102 103 104 105 106 107 108 109 110)

    log "Entering monitoring loop..."

    while true; do
        # All LB UEs migrated — just idle
        if [ "$MIGRATED_COUNT" -ge 10 ]; then
            log "All 10 LB UEs migrated to gNB2.  Monitor idle.  Ctrl+C to exit."
            sleep 60
            continue
        fi

        collect_metrics
        collect_cpu

        # Evaluate triggers
        local trigger=""
        if awk "BEGIN{exit !($LAST_AVG_DL < $DIP_THRESH)}"; then
            dip_counter=$((dip_counter + 1))
            cpu_counter=0
            trigger="DIP"
        elif awk "BEGIN{exit !($LAST_CPU > $CPU_THRESH)}"; then
            cpu_counter=$((cpu_counter + 1))
            dip_counter=0
            trigger="CPU"
        else
            dip_counter=0
            cpu_counter=0
        fi

        print_status "$dip_counter" "$cpu_counter" "$trigger"

        # Check if trigger threshold reached
        local fire=false
        [ "$trigger" = "DIP" ] && [ "$dip_counter" -ge "$DIP_COUNT" ] && fire=true
        [ "$trigger" = "CPU" ] && [ "$cpu_counter" -ge "$CPU_COUNT" ] && fire=true

        if $fire; then
            log ""
            log "══════════════════════════════════════════════════════════"
            log "TRIGGER: ${trigger} — avg_dl=${LAST_AVG_DL} Mbps/UE  cpu=${LAST_CPU}%"
            log "Migrating next LB UE to gNB2..."
            log "══════════════════════════════════════════════════════════"

            local next_ue=${lb_ues[$MIGRATED_COUNT]}
            if migrate_ue "$next_ue"; then
                MIGRATED_COUNT=$((MIGRATED_COUNT + 1))
                log "Migration ${MIGRATED_COUNT}/10 complete (UE${next_ue} on gNB2)"
            else
                log "⚠ Migration of UE${next_ue} failed — will retry next trigger cycle"
            fi

            # Reset counters after migration attempt
            dip_counter=0
            cpu_counter=0
        fi

        sleep "$POLL_SEC"
    done
}

main "$@"
