#!/bin/bash
# launch_gnb1_collectors.sh — start ALL data collectors on gNB1 (pc818)
# Called by master_lb_experiment.sh Phase 1 via SSH from uehost1
set -euo pipefail

mkdir -p /tmp/ran_collect

chmod +x /tmp/ran_collect/collect_rich_gnb1.sh /tmp/ran_collect/gnb1_sys_monitor.sh \
         /tmp/ran_collect/collect_gnb_metrics.sh /tmp/ran_collect/collect_power.sh \
         /tmp/ran_collect/collect_perf_ipc.sh 2>/dev/null || true

nohup bash /tmp/ran_collect/gnb1_sys_monitor.sh 3600 > /tmp/ran_collect/gnb1_sysmon_run.log 2>&1 &
echo "SYS_PID:$!"
sleep 1

nohup bash /tmp/ran_collect/collect_rich_gnb1.sh > /tmp/ran_collect/collect_rich_gnb1_run.log 2>&1 &
echo "RICH_PID:$!"

nohup bash /tmp/ran_collect/collect_gnb_metrics.sh 5 7200 gnb1 1 51 > /tmp/ran_collect/gnb_metrics_collect.log 2>&1 &
echo "GNB_METRICS_PID:$!"

nohup sudo bash /tmp/ran_collect/collect_power.sh 1 7200 > /tmp/ran_collect/power_collect.log 2>&1 &
echo "POWER_PID:$!"

nohup python3 /tmp/ran_collect/deep_sysmon.py 7200 2 srsenb /tmp/ran_collect/deep_sysmon_gnb1.csv > /tmp/ran_collect/deep_sysmon.log 2>&1 &
echo "DEEP_SYSMON_PID:$!"

nohup bash /tmp/ran_collect/collect_perf_ipc.sh 5 7200 > /tmp/ran_collect/perf_ipc.log 2>&1 &
echo "PERF_IPC_PID:$!"

ln -sf /tmp/ran_collect/gnb_metrics.csv /tmp/ran_collect/gnb_metrics_raw_gnb1.csv

echo "STARTED"
