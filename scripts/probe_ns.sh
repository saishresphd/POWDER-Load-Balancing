#!/bin/bash
sudo ip netns exec ue1 ip -4 addr show 2>/dev/null
echo "---"
sudo ip netns exec ue2 ip -4 addr show 2>/dev/null
echo "---"
sudo ip netns exec ue1 ping -c1 -W2 10.45.0.1 2>/dev/null | tail -3
