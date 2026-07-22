#!/bin/bash
nohup sudo bash /tmp/ran_collect/collect_power.sh 600 5 /tmp/ran_collect/power_uehost1_long.csv > /tmp/ran_collect/power_uehost1_long.log 2>&1 &
echo "PID=$!"
