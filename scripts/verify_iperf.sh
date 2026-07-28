#!/bin/bash
echo "=== iperf3 procs ==="
pgrep -a iperf3

echo "=== UE1 test ==="
sudo ip netns exec ue1 iperf3 -c 10.45.0.1 -p 5201 -u -b 1M -t 3 2>&1
