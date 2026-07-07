#!/bin/bash
# =============================================================================
# POWDER O-RAN Setup: 1 Core + 2 gNBs + 20 UEs (10 per uehost)
# Topology:
#   core    pc811  10.10.1.1  Open5GS EPC (MME+SGW+PGW)
#   gnb1    pc818  10.10.1.2  srsRAN 4G srsenb (serves UE1-10 via ZMQ)
#   gnb2    pc802  10.10.1.3  srsRAN 4G srsenb (serves UE11-20 via ZMQ)
#   uehost1 pc808  10.10.1.4  srsue x10 (UE1-10, netns ue1-ue10)
#   uehost2 pc801  10.10.1.5  srsue x10 (UE11-20, netns ue11-ue20)
#
# ZMQ Port Design (REP/REQ per UE):
#   gNB1 handles UE1-10:  gNB TX REP 2100+i, UE TX REP 2200+i
#   gNB2 handles UE11-20: gNB TX REP 2300+i, UE TX REP 2400+i
#
#   For UE i (1-10) on gNB1:
#     srsenb: tx_port=tcp://*:210i  rx_port=tcp://10.10.1.4:220i
#     srsue:  tx_port=tcp://*:220i  rx_port=tcp://10.10.1.2:210i
#
#   For UE i (11-20) on gNB2 (local index j=i-10, 1-10):
#     srsenb: tx_port=tcp://*:230j  rx_port=tcp://10.10.1.5:240j
#     srsue:  tx_port=tcp://*:240j  rx_port=tcp://10.10.1.3:230j
# =============================================================================
set -e

CORE=saish@pc811.emulab.net
GNB1=saish@pc818.emulab.net
GNB2=saish@pc802.emulab.net
UH1=saish@pc808.emulab.net
UH2=saish@pc801.emulab.net

echo "================================================"
echo " Step 1: Fix MongoDB subscribers"
echo "================================================"
ssh $CORE 'bash -s' << 'EOF'
mongosh --quiet open5gs --eval '
  db.subscribers.deleteMany({imsi: {$in: ["999700123456780","999700123456781"]}});
  print("Cleaned wrong subscribers");
  print("Total: " + db.subscribers.countDocuments());
'
EOF

echo "================================================"
echo " Step 2: Deploy gNB1 configs (UE1-10)"
echo "================================================"
scp configs/gnb1/enb.conf $GNB1:/tmp/enb1.conf
scp configs/gnb1/rr.conf  $GNB1:/tmp/rr.conf
scp configs/gnb1/sib.conf $GNB1:/tmp/sib.conf
scp configs/gnb1/rb.conf  $GNB1:/tmp/rb.conf

for i in $(seq 1 10); do
  scp configs/gnb1/enb_ue${i}.conf $GNB1:/tmp/enb_ue${i}.conf
done

ssh $GNB1 'bash -s' << 'EOF'
for f in /tmp/enb_ue*.conf; do sudo cp $f /etc/srsenb/$(basename $f); done
sudo cp /tmp/rr.conf  /etc/srsenb/rr.conf
sudo cp /tmp/sib.conf /etc/srsenb/sib.conf
sudo cp /tmp/rb.conf  /etc/srsenb/rb.conf
echo "gNB1 configs deployed"
EOF

echo "================================================"
echo " Step 3: Deploy gNB2 configs (UE11-20)"
echo "================================================"
for i in $(seq 1 10); do
  scp configs/gnb2/enb_ue${i}.conf $GNB2:/tmp/enb_ue${i}.conf
done
scp configs/gnb2/rr.conf  $GNB2:/tmp/rr.conf
scp configs/gnb2/sib.conf $GNB2:/tmp/sib.conf
scp configs/gnb2/rb.conf  $GNB2:/tmp/rb.conf

ssh $GNB2 'bash -s' << 'EOF'
for f in /tmp/enb_ue*.conf; do sudo cp $f /etc/srsenb/$(basename $f); done
sudo cp /tmp/rr.conf  /etc/srsenb/rr.conf
sudo cp /tmp/sib.conf /etc/srsenb/sib.conf
sudo cp /tmp/rb.conf  /etc/srsenb/rb.conf
echo "gNB2 configs deployed"
EOF

echo "================================================"
echo " Step 4: Deploy UE configs on uehost1 (UE1-10)"
echo "================================================"
for i in $(seq 1 10); do
  scp configs/ues/ue${i}.conf $UH1:/tmp/ue${i}.conf
done
ssh $UH1 'bash -s' << 'EOF'
for i in $(seq 1 10); do sudo cp /tmp/ue${i}.conf /etc/srsue/ue${i}.conf; done
echo "uehost1 UE configs deployed"
EOF

echo "================================================"
echo " Step 5: Deploy UE configs on uehost2 (UE11-20)"
echo "================================================"
for i in $(seq 11 20); do
  scp configs/ues/ue${i}.conf $UH2:/tmp/ue${i}.conf
done
ssh $UH2 'bash -s' << 'EOF'
for i in $(seq 11 20); do sudo cp /tmp/ue${i}.conf /etc/srsue/ue${i}.conf; done
echo "uehost2 UE configs deployed"
EOF

echo "================================================"
echo " Done. Run start_network.sh to start everything."
echo "================================================"
