#!/bin/bash
# restart_srsue_ue40_49.sh
# Kills old srsue UE40-49 processes and restarts them cleanly.
# Run on: uehost1 (pc808) AFTER fix_gnb1_ue40_49_attach.sh has run on gNB1.
# Usage: bash /proj/ATLANTIC-eVISION/exp/loadbalance/tmp/ran_9ue_lb/scripts/restart_srsue_ue40_49.sh

PROJ="/proj/ATLANTIC-eVISION/exp/loadbalance/tmp/ran_9ue_lb"
LOG="$PROJ/restart_srsue.log"

echo "[$(date)] Killing old srsue UE40-49 processes..." | tee "$LOG"
for N in $(seq 40 49); do
    sudo pkill -f "srsue.*ue${N}_patched.conf" 2>/dev/null
    sudo pkill -f "srsue.*ue${N}\.conf" 2>/dev/null
done
sleep 3

REMAINING=$(ps aux | grep srsue | grep -v grep | wc -l)
echo "[$(date)] Remaining srsue processes: $REMAINING" | tee -a "$LOG"
if [ "$REMAINING" -gt 0 ]; then
    sudo pkill -9 -f srsue 2>/dev/null
    sleep 2
fi

# Ensure netns for each UE exist
echo "[$(date)] Ensuring network namespaces exist..." | tee -a "$LOG"
for N in $(seq 40 49); do
    sudo ip netns add "ue${N}" 2>/dev/null || true
    echo "[$(date)]   netns ue${N} OK" | tee -a "$LOG"
done

# Ensure stdout log files exist with proper permissions
echo "[$(date)] Preparing log files..." | tee -a "$LOG"
for N in $(seq 40 49); do
    STDOUT="$PROJ/ue${N}_gnb1_stdout.log"
    sudo touch "$STDOUT"
    sudo chmod 666 "$STDOUT"
    # Also prepare srsue log destination if specified in config
    sudo touch "$PROJ/gnb1_logs/ue${N}_srsue.log" 2>/dev/null
    sudo chmod 666 "$PROJ/gnb1_logs/ue${N}_srsue.log" 2>/dev/null
done

# Start srsue processes one by one with a small delay
echo "[$(date)] Starting srsue UE40-49..." | tee -a "$LOG"
for N in $(seq 40 49); do
    CONF="$PROJ/ue${N}_patched.conf"
    STDOUT="$PROJ/ue${N}_gnb1_stdout.log"
    > "$STDOUT"
    nohup sudo srsue "$CONF" 0</dev/null >> "$STDOUT" 2>&1 &
    PID=$!
    echo "[$(date)]   Started ue${N} srsue PID=$PID" | tee -a "$LOG"
    sleep 1
done

# Wait for attach
echo "[$(date)] Waiting 30s for UEs to attach..." | tee -a "$LOG"
sleep 30

# Check attach status
echo "[$(date)] Checking attach status..." | tee -a "$LOG"
ATTACHED=0
for N in $(seq 40 49); do
    STDOUT="$PROJ/ue${N}_gnb1_stdout.log"
    if grep -q "Random Access Complete\|RRC Connected\|Network attach successful\|PDN connection" "$STDOUT" 2>/dev/null; then
        echo "[$(date)]   ue${N}: ATTACHED" | tee -a "$LOG"
        ATTACHED=$((ATTACHED+1))
    else
        LAST=$(tail -3 "$STDOUT" 2>/dev/null)
        echo "[$(date)]   ue${N}: NOT attached. Last: $LAST" | tee -a "$LOG"
    fi
done

echo "[$(date)] Attached: $ATTACHED/10" | tee -a "$LOG"

if [ "$ATTACHED" -ge 5 ]; then
    echo "[$(date)] >= 5 UEs attached — experiment can proceed" | tee -a "$LOG"
else
    echo "[$(date)] WARNING: Only $ATTACHED UEs attached. Check logs." | tee -a "$LOG"
fi
