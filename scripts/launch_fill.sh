#!/bin/bash
nohup bash /tmp/ran_collect/fill_missing_rates.sh > /tmp/ran_collect/fill_run.log 2>&1 &
echo "FILL_PID:$!"
