#!/bin/bash
nohup sudo bash /tmp/ran_collect/measure_power_per_ue_rate_fast.sh > /tmp/ran_collect/power_fast.log 2>&1 &
echo "PID=$!"
