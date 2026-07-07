#!/bin/bash
# =============================================================================
# stop_network.sh — Kill all running gNB/UE processes cleanly
# =============================================================================
GNB1=saish@pc818.emulab.net
GNB2=saish@pc802.emulab.net
UH1=saish@pc808.emulab.net
UH2=saish@pc801.emulab.net

echo "Stopping all srsenb and srsue processes..."
for host in $GNB1 $GNB2 $UH1 $UH2; do
  ssh $host 'bash -s' << 'KILLEOF' &
sudo pkill -9 srsenb 2>/dev/null || true
sudo pkill -9 srsue  2>/dev/null || true
sleep 2
echo "$(hostname -s): stopped"
KILLEOF
done
wait

echo "Cleaning stale tun interfaces on uehost1..."
ssh $UH1 'bash -s' << 'EOF'
for i in $(seq 1 10); do
  sudo ip netns exec ue${i} ip link del tun_srsue${i} 2>/dev/null || true
done
echo "uehost1: tun interfaces cleaned"
EOF

echo "Cleaning stale tun interfaces on uehost2..."
ssh $UH2 'bash -s' << 'EOF'
for i in $(seq 11 20); do
  sudo ip netns exec ue${i} ip link del tun_srsue${i} 2>/dev/null || true
done
echo "uehost2: tun interfaces cleaned"
EOF

echo "Done."
