#!/bin/bash
DURATION=${1:-3600}
# On core node, track open5gs processes
nohup python3 /tmp/ran_collect/deep_sysmon.py $DURATION 5 open5gs /tmp/ran_collect/deep_core.csv > /tmp/ran_collect/deep_core_run.log 2>&1 &
echo "deep_sysmon_core PID:$!"
