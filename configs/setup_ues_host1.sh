#!/bin/bash
# ==========================================================================
#  setup_ues_host1.sh  — Create 10 network namespaces + srsUE instances
#  uehost1 (pc808, 10.10.1.4) → connects to gNB1 (10.10.1.2)
#  UE 01-10: IMSI 99970000000001-10
#  Each UE gets its own netns, tun interface, and ZMQ port pair
# ==========================================================================
set -euo pipefail

GNB_IP="10.10.1.2"
HOST_IP="10.10.1.4"

# Shared keys for all UEs (lab environment)
K="00112233445566778899AABBCCDDEEFF"
OPC="63BFA50EE6523365FF14C1F45F88737D"

echo "[uehost1] Setting up 10 UE namespaces..."
sudo mkdir -p /etc/srsue

# ── Create configs for UE 1-10 ────────────────────────────────────────────
for i in $(seq 1 10); do
    IDX=$((i - 1))           # 0-based index
    IMSI=$(printf "99970%010d" $i)
    IMEI=$(printf "35349006%07d" $i)
    GNB_TX_PORT=$((2000 + IDX))   # gNB TX port this UE listens to
    UE_TX_PORT=$((2100 + IDX))    # UE TX port gNB listens to
    NS="ue${i}"

    # Create srsUE config
    sudo tee /etc/srsue/ue${i}.conf > /dev/null << UE_CONF
[rf]
freq_offset = 0
tx_gain = 80
rx_gain = 40
srate = 23.04e6
nof_antennas = 1
device_name = zmq
device_args = tx_port=tcp://*:${UE_TX_PORT},rx_port=tcp://${GNB_IP}:${GNB_TX_PORT},id=ue${i},base_srate=23.04e6

[rat.eutra]
dl_earfcn = 3350
nof_carriers = 1

[usim]
mode = soft
algo = milenage
opc  = ${OPC}
k    = ${K}
imsi = ${IMSI}
imei = ${IMEI}

[rrc]
release = 15
ue_category = 4

[nas]
apn = internet
apn_protocol = ipv4

[gw]
netns = ${NS}
ip_devname = tun_srsue${i}
ip_netmask = 255.255.255.0

[log]
all_level   = warning
filename    = /tmp/ue${i}.log

[pcap]
enable = none
UE_CONF

    # Create network namespace
    sudo ip netns del ${NS} 2>/dev/null || true
    sudo ip netns add ${NS}
    echo "  Created netns ${NS} for UE${i} (IMSI=${IMSI}, ZMQ TX=*:${UE_TX_PORT}, RX=${GNB_IP}:${GNB_TX_PORT})"
done

echo "[uehost1] All 10 UE configs ready in /etc/srsue/"
echo "Start UEs with: ./start_ues_host1.sh"
