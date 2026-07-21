#!/usr/bin/env bash
# =============================================================================
# stop_network.sh — Kill all srsenb and srsue processes on all nodes cleanly
# =============================================================================
set -euo pipefail

GNB1="saish@pc818.emulab.net"
GNB2="saish@pc802.emulab.net"
UH1="saish@pc808.emulab.net"
UH2="saish@pc801.emulab.net"

SSH="ssh -o StrictHostKeyChecking=no"

echo "Stopping all srsenb / srsue processes..."
for host in "$GNB1" "$GNB2" "$UH1" "$UH2"; do
  $SSH "$host" 'bash -s' << 'KILL' &
for P in $(ps aux | grep '[s]rsenb' | awk '{print $2}'); do sudo kill -9 $P 2>/dev/null; done
for P in $(ps aux | grep '[s]rsue'  | awk '{print $2}'); do sudo kill -9 $P 2>/dev/null; done
sleep 2
echo "$(hostname -s): stopped (srsenb=$(ps aux | grep '[s]rsenb' | wc -l) srsue=$(ps aux | grep '[s]rsue' | wc -l))"
KILL
done
wait

# Clean stale tun interfaces on uehost1 (UE1–100)
echo "Cleaning stale tun interfaces on uehost1 (UE1–100)..."
$SSH "$UH1" 'bash -s' << 'EOF'
for i in $(seq 1 100); do
  sudo ip netns exec "ue${i}" ip link del "tun_srsue${i}" 2>/dev/null || true
done
echo "uehost1: tun interfaces cleaned"
EOF

# Clean stale tun interfaces on uehost2 (UE101–110)
echo "Cleaning stale tun interfaces on uehost2 (UE101–110)..."
$SSH "$UH2" 'bash -s' << 'EOF'
for i in $(seq 101 110); do
  sudo ip netns exec "ue${i}" ip link del "tun_srsue${i}" 2>/dev/null || true
done
echo "uehost2: tun interfaces cleaned"
EOF

echo "Done. All processes stopped and tun interfaces cleaned."
