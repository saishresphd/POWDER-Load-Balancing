#!/bin/bash
# kill_all.sh — kills all srsue OR srsenb processes on this node
PROC=${1:-srsue}
echo "Killing all $PROC..."
for PID in $(ps aux | grep "$PROC" | grep -v grep | awk '{print $2}'); do
  sudo kill -9 $PID 2>/dev/null && echo "  killed $PID"
done
sleep 2
REMAINING=$(ps aux | grep "$PROC" | grep -v grep | wc -l)
echo "$PROC remaining: $REMAINING"
