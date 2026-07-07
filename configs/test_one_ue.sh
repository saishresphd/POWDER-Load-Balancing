#!/bin/bash
# test_one_ue.sh — Single UE end-to-end test
# core (pc811) + gnb1 (pc818) + UE1 (pc808)
# UE1 ZMQ: gNB tx=2010 UE-rx, UE tx=2011 gNB-rx

set -e
CORE=saish@pc811.emulab.net
GNB1=saish@pc818.emulab.net
UH1=saish@pc808.emulab.net

echo "========================================"
echo " STEP 1 — Kill all leftover processes"
echo "========================================"
for h in $GNB1 $UH1; do
  ssh $h 'bash -s' << 'EOF' &
sudo pkill -9 srsenb 2>/dev/null || true
sudo pkill -9 srsue  2>/dev/null || true
sleep 2
echo "$(hostname -s): clean"
EOF
done
wait

echo ""
echo "========================================"
echo " STEP 2 — Write enb_ue1.conf on gNB1"
echo "========================================"
ssh $GNB1 'bash -s' << 'EOF'
sudo tee /etc/srsenb/enb_ue1.conf > /dev/null << 'CONF'
[enb]
enb_id = 0x001
mcc = 999
mnc = 70
mme_addr = 10.10.1.1
gtp_bind_addr = 10.10.1.2
s1c_bind_addr = 10.10.1.2
s1c_bind_port = 0
n_prb = 50

[enb_files]
sib_config = /etc/srsenb/sib.conf
rr_config  = /etc/srsenb/rr.conf
rb_config  = /etc/srsenb/rb.conf

[rf]
dl_earfcn = 3350
tx_gain   = 80
rx_gain   = 40
device_name = zmq
device_args = fail_on_disconnect=true,tx_port=tcp://*:2010,rx_port=tcp://10.10.1.4:2011,id=enb1,base_srate=11.52e6

[expert]
rrc_inactivity_timer = -1
metrics_csv_enable   = true
metrics_csv_filename = /tmp/gnb1_ue1_metrics.csv
metrics_period_secs  = 1

[log]
all_level    = info
filename     = /tmp/gnb1_ue1.log
file_max_size = -1

[pcap]
enable = false
CONF
echo "gNB1 enb_ue1.conf written"
EOF

echo ""
echo "========================================"
echo " STEP 3 — Write ue1.conf on uehost1"
echo "========================================"
ssh $UH1 'bash -s' << 'EOF'
sudo tee /etc/srsue/ue1.conf > /dev/null << 'CONF'
[rf]
freq_offset  = 0
tx_gain      = 80
rx_gain      = 40
nof_antennas = 1
device_name  = zmq
device_args  = fail_on_disconnect=true,tx_port=tcp://*:2011,rx_port=tcp://10.10.1.2:2010,id=ue1,base_srate=11.52e6

[rat.eutra]
dl_earfcn    = 3350
nof_carriers = 1

[usim]
mode = soft
algo = milenage
opc  = 63bfa50ee6523365ff14c1f45f88737d
k    = 00112233445566778899aabbccddeeff
imsi = 999700000000001
imei = 353490060000001

[rrc]
release     = 15
ue_category = 4

[nas]
apn          = internet
apn_protocol = ipv4

[gw]
ip_devname = tun_srsue1
ip_netmask = 255.255.255.0

[log]
all_level    = info
filename     = /tmp/ue1.log
file_max_size = -1
CONF
# Remove stale tun
sudo ip link del tun_srsue1 2>/dev/null || true
sudo ldconfig
echo "UE1 config written, tun cleared"
EOF

echo ""
echo "========================================"
echo " STEP 4 — Restart MME (clear stale state)"
echo "========================================"
ssh $CORE 'bash -s' << 'EOF'
sudo systemctl restart open5gs-mmed
sleep 3
sudo systemctl is-active open5gs-mmed
echo "MME restarted"
EOF

echo ""
echo "========================================"
echo " STEP 5 — Start gNB1"
echo "========================================"
ssh $GNB1 'bash -s' << 'EOF'
sudo ldconfig
rm -f /tmp/gnb1_ue1_stdout.log
sudo srsenb /etc/srsenb/enb_ue1.conf > /tmp/gnb1_ue1_stdout.log 2>&1 &
echo $! > /tmp/gnb1_ue1.pid
echo "gNB1 PID=$(cat /tmp/gnb1_ue1.pid)"
EOF

echo "Waiting 8s for gNB1 to register with MME..."
sleep 8

ssh $CORE 'sudo tail -4 /var/log/open5gs/mme.log'

echo ""
echo "========================================"
echo " STEP 6 — Start UE1"
echo "========================================"
ssh $UH1 'bash -s' << 'EOF'
rm -f /tmp/ue1_stdout.log
sudo srsue /etc/srsue/ue1.conf > /tmp/ue1_stdout.log 2>&1 &
echo $! > /tmp/ue1.pid
echo "UE1 PID=$(cat /tmp/ue1.pid)"
EOF

echo "Waiting 30s for UE1 to attach..."
sleep 30

echo ""
echo "========================================"
echo " STEP 7 — Check UE1 attach status"
echo "========================================"
ssh $UH1 'bash -s' << 'EOF'
echo "--- UE1 tun interface ---"
ip addr show tun_srsue1 2>/dev/null || echo "NO TUN — not attached"

echo ""
echo "--- UE1 key log events ---"
grep -E "(Found cell|Attach Accept|Attach complete|GW|DRB|bearer|Can't deliver|Connected)" \
  /tmp/ue1.log 2>/dev/null | tail -15
EOF

echo ""
echo "========================================"
echo " STEP 8 — MME attach confirmation"
echo "========================================"
ssh $CORE 'bash -s' << 'EOF'
echo "--- MME last 15 lines ---"
sudo tail -15 /var/log/open5gs/mme.log
EOF

echo ""
echo "========================================"
echo " STEP 9 — Data plane ping test"
echo "========================================"
ssh $UH1 'bash -s' << 'EOF'
TUN_IP=$(ip addr show tun_srsue1 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1)
if [ -z "$TUN_IP" ]; then
  echo "SKIP: tun_srsue1 not up"
  exit 0
fi
echo "UE1 IP: $TUN_IP"
echo ""
echo "--- Ping 10.45.0.1 (core UPF gateway) ---"
ping -c 5 -W 2 -I tun_srsue1 10.45.0.1
EOF
