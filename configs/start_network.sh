#!/usr/bin/env bash
# =============================================================================
# start_network.sh
#
# Start the full 110-UE O-RAN ZMQ simulation in the correct order:
#   1. Kill any stale processes on all nodes
#   2. Ensure IP aliases are in place
#   3. Deploy configs to all nodes
#   4. Start gNB1 (110 srsenb slots: UE1–100 base + UE101–110 LB)
#   5. Start gNB2 (10 srsenb LB-target slots — idle until handover trigger)
#   6. Start UE1–100 on uehost1  (→ gNB1)
#   7. Start UE101–110 on uehost2 (→ gNB1, using ueN_gnb1.conf)
#   8. Verify attachments
# =============================================================================
set -euo pipefail

CORE="saish@pc811.emulab.net"
GNB1="saish@pc818.emulab.net"
GNB2="saish@pc802.emulab.net"
UH1="saish@pc808.emulab.net"
UH2="saish@pc801.emulab.net"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH="ssh -o StrictHostKeyChecking=no"

# ── 1. Kill all existing processes ────────────────────────────────────────────
echo "============================================================"
echo " [1/8] Kill all existing srsenb / srsue processes"
echo "============================================================"
for host in "$GNB1" "$GNB2" "$UH1" "$UH2"; do
  $SSH "$host" 'bash -s' << 'KILL' &
for P in $(ps aux | grep '[s]rsenb' | awk '{print $2}'); do sudo kill -9 $P 2>/dev/null; done
for P in $(ps aux | grep '[s]rsue'  | awk '{print $2}'); do sudo kill -9 $P 2>/dev/null; done
sleep 2
echo "$(hostname -s): killed"
KILL
done
wait
sleep 3

# ── 2. IP aliases ──────────────────────────────────────────────────────────────
echo "============================================================"
echo " [2/8] Ensure IP aliases are present on gNB1 and gNB2"
echo "============================================================"
bash "$SCRIPT_DIR/setup_aliases.sh"

# ── 3. Deploy configs ──────────────────────────────────────────────────────────
echo "============================================================"
echo " [3/8] Deploy configs to gNB1, gNB2, uehost1, uehost2"
echo "============================================================"

# gNB1 — 110 enb confs + rr/sib/rb
for f in "$SCRIPT_DIR"/gnb1/enb_ue*.conf \
         "$SCRIPT_DIR"/gnb1/rr.conf; do
  scp -q "$f" "$GNB1:/tmp/$(basename "$f")"
done
$SSH "$GNB1" 'bash -s' << 'EOF'
sudo cp /tmp/enb_ue*.conf /etc/srsenb/
sudo cp /tmp/rr.conf      /etc/srsenb/
echo "gNB1: configs deployed ($(ls /etc/srsenb/enb_ue*.conf | wc -l) enb slots)"
EOF

# gNB2 — 10 LB-target enb confs + rr/sib/rb
for f in "$SCRIPT_DIR"/gnb2/enb_ue*.conf \
         "$SCRIPT_DIR"/gnb2/rr.conf; do
  scp -q "$f" "$GNB2:/tmp/$(basename "$f")"
done
$SSH "$GNB2" 'bash -s' << 'EOF'
sudo cp /tmp/enb_ue*.conf /etc/srsenb/
sudo cp /tmp/rr.conf      /etc/srsenb/
echo "gNB2: configs deployed ($(ls /etc/srsenb/enb_ue*.conf | wc -l) enb slots)"
EOF

# uehost1 — UE1–100
for i in $(seq 1 100); do
  scp -q "$SCRIPT_DIR/ues/ue${i}.conf" "$UH1:/tmp/ue${i}.conf"
done
$SSH "$UH1" 'bash -s' << 'EOF'
for i in $(seq 1 100); do sudo cp /tmp/ue${i}.conf /etc/srsue/; done
for i in $(seq 1 100); do
  ip netns list 2>/dev/null | grep -q "^ue${i}$" || sudo ip netns add "ue${i}"
  sudo ip netns exec "ue${i}" ip link del "tun_srsue${i}" 2>/dev/null || true
done
echo "uehost1: UE1–100 configs deployed, netns ready"
EOF

# uehost2 — UE101–110 (initial _gnb1 variants)
for i in $(seq 101 110); do
  scp -q "$SCRIPT_DIR/ues/ue${i}_gnb1.conf" "$UH2:/tmp/ue${i}_gnb1.conf"
  scp -q "$SCRIPT_DIR/ues/ue${i}.conf"      "$UH2:/tmp/ue${i}.conf"
done
$SSH "$UH2" 'bash -s' << 'EOF'
for i in $(seq 101 110); do
  sudo cp /tmp/ue${i}_gnb1.conf /etc/srsue/
  sudo cp /tmp/ue${i}.conf      /etc/srsue/
done
for i in $(seq 101 110); do
  ip netns list 2>/dev/null | grep -q "^ue${i}$" || sudo ip netns add "ue${i}"
  sudo ip netns exec "ue${i}" ip link del "tun_srsue${i}" 2>/dev/null || true
done
echo "uehost2: UE101–110 configs deployed, netns ready"
EOF

# ── 4. Start gNB1 (110 srsenb slots) ──────────────────────────────────────────
echo "============================================================"
echo " [4/8] Start gNB1 — 110 srsenb slots (UE1–100 base + UE101–110 LB)"
echo "============================================================"
$SSH "$GNB1" 'bash -s' << 'EOF'
mkdir -p /tmp/gnb1_logs
# Start all 110 slots with a small stagger to avoid MME flood
for i in $(seq 1 110); do
  sudo bash -c "srsenb /etc/srsenb/enb_ue${i}.conf \
    >> /tmp/gnb1_logs/ue${i}_stdout.log 2>&1 &"
  # brief stagger every 10 slots
  [ $((i % 10)) -eq 0 ] && sleep 1
done
sleep 8
RUNNING=$(ps aux | grep '[s]rsenb' | wc -l)
echo "gNB1: ${RUNNING} srsenb processes running"
EOF

# ── 5. Start gNB2 (10 LB-target slots — idle, ZMQ REP sockets bound) ──────────
echo "============================================================"
echo " [5/8] Start gNB2 — 10 LB-target slots (idle until handover)"
echo "============================================================"
$SSH "$GNB2" 'bash -s' << 'EOF'
mkdir -p /tmp/gnb2_logs
for i in $(seq 101 110); do
  sudo bash -c "srsenb /etc/srsenb/enb_ue${i}.conf \
    >> /tmp/gnb2_logs/ue${i}_stdout.log 2>&1 &"
  sleep 0.3
done
sleep 5
RUNNING=$(ps aux | grep '[s]rsenb' | wc -l)
echo "gNB2: ${RUNNING} srsenb processes running (LB targets, waiting for UEs)"
EOF

echo "Waiting 15s for all gNBs to register with MME..."
sleep 15

echo "=== MME: eNB S1 registrations ==="
$SSH "$CORE" "sudo tail -10 /var/log/open5gs/mme.log | grep -i 'setup\|connect' || true"

# ── 6. Start UE1–100 on uehost1 ────────────────────────────────────────────────
echo "============================================================"
echo " [6/8] Start UE1–100 on uehost1 (staggered, 10 at a time)"
echo "============================================================"
$SSH "$UH1" 'bash -s' << 'EOF'
mkdir -p /tmp/ue_logs
for i in $(seq 1 100); do
  sudo ip netns exec "ue${i}" ip link del "tun_srsue${i}" 2>/dev/null || true
  sudo bash -c "srsue /etc/srsue/ue${i}.conf \
    >> /tmp/ue_logs/ue${i}_stdout.log 2>&1 &"
  echo "  UE${i} started"
  # stagger: 2s between each UE, extra 5s pause every 10 UEs
  sleep 2
  [ $((i % 10)) -eq 0 ] && sleep 5
done
echo "uehost1: all 100 UEs started"
EOF

# ── 7. Start UE101–110 on uehost2 (→ gNB1 initially) ──────────────────────────
echo "============================================================"
echo " [7/8] Start UE101–110 on uehost2 (→ gNB1 using _gnb1.conf)"
echo "============================================================"
$SSH "$UH2" 'bash -s' << 'EOF'
mkdir -p /tmp/ue_logs
for i in $(seq 101 110); do
  sudo ip netns exec "ue${i}" ip link del "tun_srsue${i}" 2>/dev/null || true
  sudo bash -c "srsue /etc/srsue/ue${i}_gnb1.conf \
    >> /tmp/ue_logs/ue${i}_gnb1_stdout.log 2>&1 &"
  echo "  UE${i} started (→ gNB1)"
  sleep 3
done
echo "uehost2: UE101–110 started on gNB1"
EOF

echo ""
echo "Waiting 90s for all UEs to attach..."
sleep 90

# ── 8. Verify ──────────────────────────────────────────────────────────────────
echo "============================================================"
echo " [8/8] Verify attach status"
echo "============================================================"
$SSH "$UH1" 'bash -s' << 'EOF'
attached=0
for i in $(seq 1 100); do
  sudo ip netns exec "ue${i}" ip -br a 2>/dev/null | grep -q tun_ && attached=$((attached+1))
done
echo "uehost1: ${attached}/100 UEs attached"
# Show first 5 IPs as sanity check
for i in 1 2 3 4 5; do
  ip=$(sudo ip netns exec "ue${i}" ip -br a 2>/dev/null | grep tun_ | awk '{print $3}')
  echo "  UE${i}: ${ip:-NOT ATTACHED}"
done
EOF

$SSH "$UH2" 'bash -s' << 'EOF'
attached=0
for i in $(seq 101 110); do
  sudo ip netns exec "ue${i}" ip -br a 2>/dev/null | grep -q tun_ && attached=$((attached+1))
done
echo "uehost2: ${attached}/10 LB UEs attached (on gNB1)"
for i in 101 102 103; do
  ip=$(sudo ip netns exec "ue${i}" ip -br a 2>/dev/null | grep tun_ | awk '{print $3}')
  echo "  UE${i}: ${ip:-NOT ATTACHED}"
done
EOF

echo ""
echo "Network started.  Run configs/loadbalance_monitor.sh to start load monitoring."
