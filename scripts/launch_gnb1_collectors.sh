#!/bin/bash
chmod +x /tmp/ran_collect/collect_rich_gnb1.sh /tmp/ran_collect/gnb1_sys_monitor.sh
nohup bash /tmp/ran_collect/gnb1_sys_monitor.sh 3600 > /tmp/ran_collect/gnb1_sysmon_run.log 2>&1 &
echo "SYS_PID:$!"
sleep 1
nohup bash /tmp/ran_collect/collect_rich_gnb1.sh > /tmp/ran_collect/collect_rich_gnb1_run.log 2>&1 &
echo "RICH_PID:$!"
echo "STARTED"
