#!/bin/bash
DURATION=${1:-3600}
nohup python3 /tmp/ran_collect/deep_sysmon.py $DURATION 5 srsue /tmp/ran_collect/deep_uehost1.csv > /tmp/ran_collect/deep_uehost1_run.log 2>&1 &
echo "deep_sysmon_uehost1 PID:$!"
