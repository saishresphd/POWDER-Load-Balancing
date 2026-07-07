#!/bin/bash
# Single UE attach test — runs from local Mac, SSHes to nodes
# Tests gNB1 (pc818) + UE1 (pc808) attach and data plane

set -e
GNB1=saish@pc818.emulab.net
UE1=saish@pc808.emulab.net
CORE=saish@pc811.emulab.net

echo "=============================="
echo "STEP 1: Kill any leftover processes"
echo "=============================="
ssh $GNB1 'bash -s' << 'EOF'
sudo pkill -9 srsenb 2>/dev/null || true
sleep 1
echo "gnb1 clean"
EOF

ssh $UE1 'bash -s' << 'EOF'
sudo pkill -9 srsue 2>/dev/null || true
sleep 1
# Clean any stale tun in netns
sudo ip netns exec ue1 ip link del tun_srsue1 2>/dev/null || true
echo "uehost1 clean"
EOF

echo ""
echo "=============================="
echo "STEP 2: Start gNB1"
echo "=============================="
ssh $GNB1 'bash -s' << 'EOF'
sudo srsenb /etc/srsenb/enb.conf > /tmp/gnb_stdout.log 2>&1 &
echo $! > /tmp/gnb1.pid
echo "gNB1 started PID=$(cat /tmp/gnb1.pid)"
EOF

echo "Waiting 8s for gNB1 to register with MME..."
sleep 8

echo ""
echo "=============================="
echo "STEP 3: Verify gNB1 registered with MME"
echo "=============================="
ssh $CORE 'bash -s' << 'EOF'
echo "=== MME last 5 lines ==="
sudo tail -5 /var/log/open5gs/mme.log
EOF

echo ""
echo "=============================="
echo "STEP 4: Start UE1 in netns ue1"
echo "=============================="
ssh $UE1 'bash -s' << 'EOF'
sudo ip netns exec ue1 \
  srsue /etc/srsue/ue1.conf > /tmp/ue1_out.log 2>&1 &
echo $! > /tmp/ue1.pid
echo "UE1 started PID=$(cat /tmp/ue1.pid)"
EOF

echo "Waiting 30s for UE1 attach..."
sleep 30

echo ""
echo "=============================="
echo "STEP 5: Check UE1 attach status"
echo "=============================="
ssh $UE1 'bash -s' << 'EOF'
echo "=== UE1 log tail ==="
tail -30 /tmp/ue1_out.log
echo ""
echo "=== tun_srsue1 in netns ue1 ==="
sudo ip netns exec ue1 ip addr show tun_srsue1 2>/dev/null || echo "NO TUN INTERFACE - attach failed"
EOF

echo ""
echo "=============================="
echo "STEP 6: MME attach log"
echo "=============================="
ssh $CORE 'bash -s' << 'EOF'
echo "=== MME last 20 lines ==="
sudo tail -20 /var/log/open5gs/mme.log
EOF

echo ""
echo "=============================="
echo "STEP 7: Ping test (if tun up)"
echo "=============================="
ssh $UE1 'bash -s' << 'EOF'
if sudo ip netns exec ue1 ip addr show tun_srsue1 2>/dev/null | grep -q "10.45"; then
  echo "=== Pinging 10.45.0.1 from UE1 netns ==="
  sudo ip netns exec ue1 ping -c 4 -W 2 10.45.0.1
else
  echo "SKIP: tun_srsue1 not up yet"
fi
EOF
