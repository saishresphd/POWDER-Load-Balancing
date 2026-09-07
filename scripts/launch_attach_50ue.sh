#!/bin/bash
# launch_attach_50ue.sh — wrapper to run attach_50ue_fast.sh 1-50 in background
# Deploy to NFS, run: bash /proj/.../scripts/launch_attach_50ue.sh

PROJ="/proj/ATLANTIC-eVISION/exp/loadbalance/tmp/ran_9ue_lb"
SCRIPT="$PROJ/scripts/attach_50ue_fast.sh"
LOG="/tmp/ran_collect/attach_50ue_run.log"

mkdir -p /tmp/ran_collect /tmp/ue_logs

echo "[$(date)] Launching attach_50ue_fast.sh 1 50 35 in background"
nohup bash "$SCRIPT" 1 50 35 >"$LOG" 2>&1 </dev/null &
PID=$!
echo "[$(date)] PID=$PID — monitor with: tail -f $LOG"
echo $PID > /tmp/ran_collect/attach_50ue.pid
