#!/bin/bash
# launch_deep_sysmon.sh — deploys and starts deep_sysmon.py on gnb1, uehost1, core
# Usage: bash launch_deep_sysmon.sh [duration_s]
DURATION=${1:-3600}
echo "[launch] duration=${DURATION}s"
nohup python3 /tmp/ran_collect/deep_sysmon.py $DURATION 5 srsenb /tmp/ran_collect/deep_gnb1.csv > /tmp/ran_collect/deep_gnb1_run.log 2>&1 &
echo "deep_sysmon_gnb1 PID:$!"
