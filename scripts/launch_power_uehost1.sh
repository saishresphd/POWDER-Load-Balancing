#!/bin/bash
nohup sudo bash /tmp/ran_collect/collect_power.sh 120 2 /tmp/ran_collect/power_uehost1.csv > /tmp/ran_collect/power_uehost1.log 2>&1 &
echo "PID=$!"
