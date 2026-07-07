#!/bin/bash
# ==========================================================================
#  setup_ues_host2.sh  — Create 10 network namespaces + srsUE instances
#  uehost2 (pc801, 10.10.1.5) → connects to gNB2 (10.10.1.3)
#  UE 11-20: IMSI 99970000000011-20
# ==========================================================================
set -euo pipefail

GNB_IP="10.10.1.3"
HOST_IP="10.10.1.5"

K="00112233445566778899AABBCCDDEEFF"
OPC="63BFA50EE6523365FF14C1F45F88737D"

echo "[uehost2] Setting up 10 UE namespaces..."
sudo mkdir -p /etc/srsue

for i in $(seq 1 10); do
    GLOBAL_UE=$((i + 10))         # UE11-20 globally
    IDX=$((i - 1))                 # 0-based index for port
    IMSI=$(printf "99970%010d" $GLOBAL_UE)
    IMEI=$(printf "35349006%07d" $GLOBAL_UE)
    GNB_TX_PORT=$((2000 + IDX))
    UE_TX_PORT=$((2100 + IDX))
    NS="ue${GLOBAL_UE}"

    sudo tee /etc/srsue/ue${GLOBAL_UE}.conf > /dev/null << UE_CONF
[rf]
freq_offset = 0
tx_gain = 80
rx_gain = 40
srate = 23.04e6
nof_antennas = 1
device_name = zmq
device_args = tx_port=tcp://*:${UE_TX_PORT},rx_port=tcp://${GNB_IP}:${GNB_TX_PORT},id=ue${GLOBAL_UE},base_srate=23.04e6

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
ip_devname = tun_srsue${GLOBAL_UE}
ip_netmask = 255.255.255.0

[log]
all_level   = warning
filename    = /tmp/ue${GLOBAL_UE}.log

[pcap]
enable = none
UE_CONF

    sudo ip netns del ${NS} 2>/dev/null || true
    sudo ip netns add ${NS}
    echo "  Created netns ${NS} for UE${GLOBAL_UE} (IMSI=${IMSI})"
done

echo "[uehost2] All 10 UE configs ready in /etc/srsue/"
