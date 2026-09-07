#!/bin/bash
# fix_gnb1_ue40_49_attach.sh
# Fixes the fail_on_disconnect=true crash loop on gNB1 ue40-49 srsenb slots
# and restarts them cleanly so srsue UE40-49 can attach.
#
# Run on: gNB1 (pc818) as regular user (uses sudo internally)
# Usage: bash /proj/ATLANTIC-eVISION/exp/loadbalance/tmp/ran_9ue_lb/scripts/fix_gnb1_ue40_49_attach.sh

PROJ="/proj/ATLANTIC-eVISION/exp/loadbalance/tmp/ran_9ue_lb"
LOG="$PROJ/fix_attach.log"
METRICS_DIR="$PROJ/gnb1_metrics"
LOGS_DIR="$PROJ/gnb1_logs"

echo "[$(date)] Starting gNB1 ue40-49 attach fix" | tee "$LOG"

# Step 1: Kill all current ue40-49 srsenb slots (they are crash-looping)
echo "[$(date)] Killing all ue40-49 srsenb slots..." | tee -a "$LOG"
for N in $(seq 40 49); do
    sudo pkill -f "srsenb /etc/srsenb/enb_ue${N}.conf" 2>/dev/null
done
sleep 3

# Verify they are gone
REMAINING=$(ps aux | grep srsenb | grep -v grep | grep -E "enb_ue4[0-9].conf" | wc -l)
echo "[$(date)] Remaining ue40-49 srsenb processes: $REMAINING" | tee -a "$LOG"
if [ "$REMAINING" -gt 0 ]; then
    echo "[$(date)] Force killing remaining..." | tee -a "$LOG"
    for N in $(seq 40 49); do
        sudo kill -9 $(pgrep -f "enb_ue${N}.conf" 2>/dev/null) 2>/dev/null
    done
    sleep 2
fi

# Step 2: Patch all 10 configs to remove fail_on_disconnect=true
# Replace with fail_on_disconnect=false so ZMQ waits for UE
echo "[$(date)] Patching enb_ue40-49.conf to remove fail_on_disconnect=true..." | tee -a "$LOG"
for N in $(seq 40 49); do
    CONF="/etc/srsenb/enb_ue${N}.conf"
    if sudo grep -q "fail_on_disconnect=true" "$CONF" 2>/dev/null; then
        sudo sed -i 's/fail_on_disconnect=true/fail_on_disconnect=false/g' "$CONF"
        echo "[$(date)]   Patched $CONF" | tee -a "$LOG"
    else
        echo "[$(date)]   $CONF already OK (no fail_on_disconnect=true)" | tee -a "$LOG"
    fi
done

# Step 3: Ensure metrics/logs dirs are writable by root (srsenb runs as root)
echo "[$(date)] Ensuring /proj metric/log dirs are writable..." | tee -a "$LOG"
sudo chmod 777 "$METRICS_DIR" "$LOGS_DIR"
for N in $(seq 40 49); do
    sudo touch "$METRICS_DIR/ue${N}.csv" "$LOGS_DIR/ue${N}.log"
    sudo chmod 666 "$METRICS_DIR/ue${N}.csv" "$LOGS_DIR/ue${N}.log"
done

# Step 4: Restart all 10 srsenb slots with stdin from /dev/null
echo "[$(date)] Starting ue40-49 srsenb slots with 0</dev/null..." | tee -a "$LOG"
for N in $(seq 40 49); do
    CONF="/etc/srsenb/enb_ue${N}.conf"
    STDOUT_LOG="$LOGS_DIR/ue${N}_stdout.log"
    # Truncate old stdout logs so we get fresh data
    > "$STDOUT_LOG"
    nohup sudo srsenb "$CONF" 0</dev/null >> "$STDOUT_LOG" 2>&1 &
    PID=$!
    echo "[$(date)]   Started ue${N} srsenb PID=$PID" | tee -a "$LOG"
    sleep 0.5
done

# Step 5: Wait for SCTP connections to MME
echo "[$(date)] Waiting 15s for SCTP connections to MME..." | tee -a "$LOG"
sleep 15

# Check SCTP state
SCTP_COUNT=$(netstat -tn 2>/dev/null | grep "10.10.1.1" | grep ESTABLISHED | wc -l)
echo "[$(date)] SCTP ESTABLISHED connections to MME: $SCTP_COUNT" | tee -a "$LOG"

# Check srsenb procs
RUNNING=$(ps aux | grep srsenb | grep -v grep | grep -E "enb_ue4[0-9].conf" | wc -l)
echo "[$(date)] ue40-49 srsenb processes running: $RUNNING" | tee -a "$LOG"

if [ "$RUNNING" -ge 10 ]; then
    echo "[$(date)] SUCCESS: All 10 srsenb slots running" | tee -a "$LOG"
    echo "[$(date)] Now restart srsue UE40-49 on uehost1 (pc808)" | tee -a "$LOG"
else
    echo "[$(date)] WARNING: Only $RUNNING/10 slots running. Check stdout logs." | tee -a "$LOG"
    for N in $(seq 40 49); do
        echo "--- ue${N} stdout ---"
        tail -5 "$LOGS_DIR/ue${N}_stdout.log" 2>/dev/null
    done
fi

echo "[$(date)] Fix script done." | tee -a "$LOG"
