#!/bin/bash
pkill -f "iperf3 -s" 2>/dev/null || true
sleep 1
nohup iperf3 -s -p 5201 -i 0 > /tmp/iperf3_server.log 2>&1 &
echo "iperf3 server PID=$!"
sleep 1
pgrep -a iperf3
