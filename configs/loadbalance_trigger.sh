#!/bin/bash
# ==========================================================================
#  loadbalance_trigger.sh  — Monitor gNB1 UE count, trigger handover
#  Logic: when gNB1 has >= THRESHOLD UEs, move excess UEs to gNB2
#
#  In srsRAN 4G simulation (ZMQ), "handover" = stop UE N on gNB1,
#  update its config to point to gNB2 ZMQ ports, restart UE.
#
#  Run on: uehost1 (pc808) where gNB1 UEs are managed
# ==========================================================================

THRESHOLD=8           # Trigger when gNB1 has this many attached UEs
CHECK_INTERVAL=5      # Seconds between checks
GNB2_IP="10.10.1.3"  # gNB2 ZMQ TX IP

# Port mapping: when UE moves to gNB2
# UE i on host1 gets gNB2 ports starting at 200+i (extra range)
GNB2_BASE_PORT=2010   # gNB2 ports 2010-2019 for handed-over UEs
UE_TX_BASE=2110       # UE TX ports 2110-2119

LOG=/tmp/loadbalance.log
echo "[$(date)] Load-balancer started. Threshold=${THRESHOLD} UEs on gNB1" | tee -a $LOG

get_attached_ues() {
    # Count UEs with active tun_srsue interfaces in their namespace
    local count=0
    for i in $(seq 1 10); do
        if sudo ip netns exec ue${i} ip addr show tun_srsue${i} 2>/dev/null | grep -q "inet "; then
            count=$((count + 1))
        fi
    done
    echo $count
}

get_ue_throughput() {
    # Sum all UE namespace traffic (rough throughput measure)
    local total_rx=0
    for i in $(seq 1 10); do
        local rx=$(sudo ip netns exec ue${i} cat /sys/class/net/tun_srsue${i}/statistics/rx_bytes 2>/dev/null || echo 0)
        total_rx=$((total_rx + rx))
    done
    echo $total_rx
}

handover_ue_to_gnb2() {
    local ue_id=$1
    local slot=$2   # 0-based slot on gNB2

    local gnb2_tx_port=$((GNB2_BASE_PORT + slot))
    local ue_tx_port=$((UE_TX_BASE + slot))
    local imsi=$(printf "99970%010d" $ue_id)

    echo "[$(date)] HANDOVER: Moving UE${ue_id} (IMSI=${imsi}) to gNB2 port ${gnb2_tx_port}" | tee -a $LOG

    # Kill current UE process
    sudo pkill -f "srsue /etc/srsue/ue${ue_id}.conf" 2>/dev/null || true
    sleep 1

    # Update UE config to point to gNB2
    sudo tee /etc/srsue/ue${ue_id}_gnb2.conf > /dev/null << UE_CONF
[rf]
freq_offset = 0
tx_gain = 80
rx_gain = 40
srate = 23.04e6
nof_antennas = 1
device_name = zmq
device_args = tx_port=tcp://*:${ue_tx_port},rx_port=tcp://${GNB2_IP}:${gnb2_tx_port},id=ue${ue_id}_gnb2,base_srate=23.04e6

[rat.eutra]
dl_earfcn = 3350
nof_carriers = 1

[usim]
mode = soft
algo = milenage
opc  = 63BFA50EE6523365FF14C1F45F88737D
k    = 00112233445566778899AABBCCDDEEFF
imsi = ${imsi}
imei = $(printf "35349006%07d" $ue_id)

[rrc]
release = 15
ue_category = 4

[nas]
apn = internet
apn_protocol = ipv4

[gw]
netns = ue${ue_id}
ip_devname = tun_srsue${ue_id}
ip_netmask = 255.255.255.0

[log]
all_level   = warning
filename    = /tmp/ue${ue_id}_gnb2.log

[pcap]
enable = none
UE_CONF

    # Restart UE with gNB2 config
    sudo srsue /etc/srsue/ue${ue_id}_gnb2.conf >> /tmp/ue_logs/ue${ue_id}_gnb2_stdout.log 2>&1 &
    echo "[$(date)] UE${ue_id} restarted targeting gNB2" | tee -a $LOG
}

# Main monitoring loop
HANDOVER_DONE=()
SLOT=0

while true; do
    ATTACHED=$(get_attached_ues)
    TS=$(date +%s)
    
    echo "[$(date +%H:%M:%S)] gNB1 attached UEs: ${ATTACHED}/${THRESHOLD}" | tee -a $LOG
    
    # Log CPU of gNB1 process
    GNB1_CPU=$(ps aux | awk '/srsenb/{sum+=$3} END{printf "%.1f",sum}')
    echo "  gNB1 CPU: ${GNB1_CPU}%" | tee -a $LOG
    
    # Trigger handover if threshold exceeded
    if [ "$ATTACHED" -ge "$THRESHOLD" ]; then
        echo "[$(date)] THRESHOLD REACHED (${ATTACHED} >= ${THRESHOLD}). Initiating handover..." | tee -a $LOG
        
        # Move UEs 9 and 10 to gNB2 (highest index = least disruptive)
        for ue_id in 10 9; do
            if [[ ! " ${HANDOVER_DONE[*]} " =~ " ${ue_id} " ]]; then
                handover_ue_to_gnb2 $ue_id $SLOT
                HANDOVER_DONE+=($ue_id)
                SLOT=$((SLOT + 1))
                sleep 2
            fi
        done
        echo "[$(date)] Handover complete. UEs on gNB1: ~$((ATTACHED-2)), moved to gNB2: ${#HANDOVER_DONE[@]}" | tee -a $LOG
    fi
    
    sleep $CHECK_INTERVAL
done
