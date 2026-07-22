#!/bin/bash
nohup bash /tmp/ran_collect/retest_failed_ues.sh > /tmp/ran_collect/retest_run.log 2>&1 &
echo "RETEST_PID:$!"
