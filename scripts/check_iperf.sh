#!/bin/bash
echo "=== iperf3 server status on core ==="
ssh saish@pc811.emulab.net "ps aux" | grep iperf3 || echo "none on core"

echo "=== iperf3 server status on gnb1 ==="
ssh saish@pc818.emulab.net "ps aux" | grep iperf3 || echo "none on gnb1"

echo "=== test iperf3 from UE1 ==="
sudo ip netns exec ue1 iperf3 -c 10.45.0.1 -p 5201 -u -b 1M -t 3 2>&1 | tail -8
