#!/bin/bash
pkill -f 'iperf3 -s' 2>/dev/null
sleep 1
iperf3 -s -p 5201 -i 0 -D
sleep 1
echo "running:"
pgrep -a iperf3
