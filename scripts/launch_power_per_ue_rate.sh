#!/bin/bash
nohup sudo bash /tmp/ran_collect/measure_power_per_ue_rate.sh > /tmp/ran_collect/power_per_ue_rate.log 2>&1 &
echo "PID=$!"
