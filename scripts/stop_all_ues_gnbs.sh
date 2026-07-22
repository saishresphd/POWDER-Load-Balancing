#!/bin/bash
# ─── stop_all_ues_gnbs.sh ────────────────────────────────────────────────────
# Kill all srsue or srsenb processes on this node.
# Usage: bash stop_all_ues_gnbs.sh srsue   OR   bash stop_all_ues_gnbs.sh srsenb

PROC=${1:-srsue}
echo "Stopping all $PROC processes..."

for PID in $(ps aux | grep "$PROC" | grep -v grep | awk '{print $2}'); do
  sudo kill -9 $PID 2>/dev/null && echo "Killed PID $PID"
done

sleep 2
REMAINING=$(ps aux | grep "$PROC" | grep -v grep | wc -l)
echo "$REMAINING $PROC processes remaining"
