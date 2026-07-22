#!/bin/bash
nohup python3 /tmp/ran_collect/collect_rich_gnb1.py > /tmp/ran_collect/collect_rich_gnb1_py.log 2>&1 &
echo "PY_PID:$!"
