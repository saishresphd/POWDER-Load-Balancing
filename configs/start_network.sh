#!/bin/bash
# =============================================================================
# start_network.sh — Start the full O-RAN ZMQ simulation
# Order: kill all → deploy configs → start core → start gNBs → start UEs
# =============================================================================
set -e

CORE=saish@pc811.emulab.net
GNB1=saish@pc818.emulab.net
GNB2=saish@pc802.emulab.net
UH1=saish@pc808.emulab.net
UH2=saish@pc801.emulab.net

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "============================================================"
echo " [1/6] Kill all existing srsenb/srsue processes"
echo "============================================================"
for host in $GNB1 $GNB2 $UH1 $UH2; do
  ssh $host 'bash -s' << 'KILLEOF' &
sudo pkill -9 srsenb 2>/dev/null || true
sudo pkill -9 srsue  2>/dev/null || true
# Wait for ports to be released
sleep 3
echo "$(hostname -s): processes killed"
KILLEOF
done
wait
sleep 3

echo "============================================================"
echo " [2/6] Fix MongoDB: remove stale test subscribers"
echo "============================================================"
ssh $CORE 'bash -s' << 'EOF'
mongosh --quiet open5gs --eval '
  db.subscribers.deleteMany({imsi: {$in: ["999700123456780","999700123456781"]}});
  var count = db.subscribers.countDocuments();
  print("Subscribers in DB: " + count);
'
EOF

echo "============================================================"
echo " [3/6] Deploy configs to gNB1, gNB2, uehost1, uehost2"
echo "============================================================"
# --- gNB1 ---
for f in $SCRIPT_DIR/gnb1/enb_ue*.conf \
          $SCRIPT_DIR/gnb1/rr.conf \
          $SCRIPT_DIR/gnb1/sib.conf \
          $SCRIPT_DIR/gnb1/rb.conf; do
  scp -q "$f" $GNB1:/tmp/$(basename $f)
done
ssh $GNB1 'bash -s' << 'EOF'
sudo cp /tmp/enb_ue*.conf /etc/srsenb/
sudo cp /tmp/rr.conf /tmp/sib.conf /tmp/rb.conf /etc/srsenb/
sudo ldconfig
echo "gNB1: configs deployed"
EOF

# --- gNB2 ---
for f in $SCRIPT_DIR/gnb2/enb_ue*.conf \
          $SCRIPT_DIR/gnb2/rr.conf \
          $SCRIPT_DIR/gnb2/sib.conf \
          $SCRIPT_DIR/gnb2/rb.conf; do
  scp -q "$f" $GNB2:/tmp/$(basename $f)
done
ssh $GNB2 'bash -s' << 'EOF'
sudo cp /tmp/enb_ue*.conf /etc/srsenb/
sudo cp /tmp/rr.conf /tmp/sib.conf /tmp/rb.conf /etc/srsenb/
sudo ldconfig
echo "gNB2: configs deployed"
EOF

# --- uehost1 (UE1-10) ---
for i in $(seq 1 10); do
  scp -q $SCRIPT_DIR/ues/ue${i}.conf $UH1:/tmp/ue${i}.conf
done
ssh $UH1 'bash -s' << 'EOF'
for i in $(seq 1 10); do sudo cp /tmp/ue${i}.conf /etc/srsue/ue${i}.conf; done
# Create netns if missing
for i in $(seq 1 10); do
  ip netns list | grep -q "^ue${i}$" 2>/dev/null || sudo ip netns add ue${i}
done
# Clean any stale tun interfaces
for i in $(seq 1 10); do
  sudo ip netns exec ue${i} ip link del tun_srsue${i} 2>/dev/null || true
done
sudo ldconfig
echo "uehost1: configs deployed, netns ready"
EOF

# --- uehost2 (UE11-20) ---
for i in $(seq 11 20); do
  scp -q $SCRIPT_DIR/ues/ue${i}.conf $UH2:/tmp/ue${i}.conf
done
ssh $UH2 'bash -s' << 'EOF'
for i in $(seq 11 20); do sudo cp /tmp/ue${i}.conf /etc/srsue/ue${i}.conf; done
# Create netns if missing
for i in $(seq 11 20); do
  ip netns list | grep -q "^ue${i}$" 2>/dev/null || sudo ip netns add ue${i}
done
# Clean any stale tun interfaces
for i in $(seq 11 20); do
  sudo ip netns exec ue${i} ip link del tun_srsue${i} 2>/dev/null || true
done
sudo ldconfig
echo "uehost2: configs deployed, netns ready"
EOF

echo "============================================================"
echo " [4/6] Start gNBs (one srsenb per UE slot, 10 per gNB)"
echo "============================================================"
ssh $GNB1 'bash -s' << 'EOF'
mkdir -p /tmp/gnb1_logs
for i in $(seq 1 10); do
  sudo srsenb /etc/srsenb/enb_ue${i}.conf \
    --log.filename=/tmp/gnb1_logs/ue${i}.log \
    > /tmp/gnb1_logs/ue${i}_stdout.log 2>&1 &
  echo $! > /tmp/gnb1_ue${i}.pid
  sleep 0.5
done
sleep 5
echo "gNB1: started $(ls /tmp/gnb1_ue*.pid | wc -l) enb instances"
# Show MME connections
grep -l "S1Setup" /tmp/gnb1_logs/*_stdout.log 2>/dev/null | wc -l | xargs echo "Instances connected to MME:"
EOF

ssh $GNB2 'bash -s' << 'EOF'
mkdir -p /tmp/gnb2_logs
for i in $(seq 1 10); do
  sudo srsenb /etc/srsenb/enb_ue${i}.conf \
    --log.filename=/tmp/gnb2_logs/ue${i}.log \
    > /tmp/gnb2_logs/ue${i}_stdout.log 2>&1 &
  echo $! > /tmp/gnb2_ue${i}.pid
  sleep 0.5
done
sleep 5
echo "gNB2: started $(ls /tmp/gnb2_ue*.pid | wc -l) enb instances"
grep -l "S1Setup" /tmp/gnb2_logs/*_stdout.log 2>/dev/null | wc -l | xargs echo "Instances connected to MME:"
EOF

echo "Waiting 10s for gNBs to register with MME..."
sleep 10

echo "=== MME: eNB registrations ==="
ssh $CORE 'sudo tail -5 /var/log/open5gs/mme.log'

echo "============================================================"
echo " [5/6] Start UEs (staggered 2s apart)"
echo "============================================================"
ssh $UH1 'bash -s' << 'EOF'
mkdir -p /tmp/ue_logs
for i in $(seq 1 10); do
  sudo ip netns exec ue${i} ip link del tun_srsue${i} 2>/dev/null || true
  sudo srsue /etc/srsue/ue${i}.conf \
    --log.filename=/tmp/ue_logs/ue${i}.log \
    > /tmp/ue_logs/ue${i}_stdout.log 2>&1 &
  echo $! > /tmp/ue${i}.pid
  echo "  UE${i} started (PID=$!)"
  sleep 2
done
echo "uehost1: all 10 UEs started"
EOF

ssh $UH2 'bash -s' << 'EOF'
mkdir -p /tmp/ue_logs
for i in $(seq 11 20); do
  sudo ip netns exec ue${i} ip link del tun_srsue${i} 2>/dev/null || true
  sudo srsue /etc/srsue/ue${i}.conf \
    --log.filename=/tmp/ue_logs/ue${i}.log \
    > /tmp/ue_logs/ue${i}_stdout.log 2>&1 &
  echo $! > /tmp/ue${i}.pid
  echo "  UE${i} started (PID=$!)"
  sleep 2
done
echo "uehost2: all 10 UEs started"
EOF

echo "Waiting 60s for all UEs to attach..."
sleep 60

echo "============================================================"
echo " [6/6] Verify attachments"
echo "============================================================"
bash "$(dirname "$0")/check_status.sh"
