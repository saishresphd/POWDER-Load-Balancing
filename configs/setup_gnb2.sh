#!/bin/bash
# ==========================================================================
#  setup_gnb2.sh  — Deploy srsRAN 4G eNB/gNB config on gnb2 (pc802, 10.10.1.3)
#  Supports 10 simultaneous UEs via ZMQ multi-antenna mode
#  AMF: 10.10.1.1:38412 (Open5GS)
# ==========================================================================
set -euo pipefail

echo "[gnb2] Setting up config directories..."
sudo mkdir -p /etc/srsenb

sudo tee /etc/srsenb/enb.conf > /dev/null << 'ENB'
[enb]
enb_id = 0x19C
mcc = 999
mnc = 70
mme_addr = 10.10.1.1
gtp_bind_addr = 10.10.1.3
s1c_bind_addr = 10.10.1.3
s1c_bind_port = 0
n_prb = 100

[enb_files]
sib_config = /etc/srsenb/sib.conf
rr_config  = /etc/srsenb/rr.conf
rb_config  = /etc/srsenb/rb.conf

[rf]
dl_earfcn = 3350
tx_gain   = 80
rx_gain   = 40
device_name = zmq
device_args = fail_on_disconnect=false,id=enb2,base_srate=23.04e6,\
tx_port0=tcp://10.10.1.3:2000,rx_port0=tcp://10.10.1.5:2100,\
tx_port1=tcp://10.10.1.3:2001,rx_port1=tcp://10.10.1.5:2101,\
tx_port2=tcp://10.10.1.3:2002,rx_port2=tcp://10.10.1.5:2102,\
tx_port3=tcp://10.10.1.3:2003,rx_port3=tcp://10.10.1.5:2103,\
tx_port4=tcp://10.10.1.3:2004,rx_port4=tcp://10.10.1.5:2104,\
tx_port5=tcp://10.10.1.3:2005,rx_port5=tcp://10.10.1.5:2105,\
tx_port6=tcp://10.10.1.3:2006,rx_port6=tcp://10.10.1.5:2106,\
tx_port7=tcp://10.10.1.3:2007,rx_port7=tcp://10.10.1.5:2107,\
tx_port8=tcp://10.10.1.3:2008,rx_port8=tcp://10.10.1.5:2108,\
tx_port9=tcp://10.10.1.3:2009,rx_port9=tcp://10.10.1.5:2109

[log]
all_level   = warning
filename    = /tmp/gnb2.log

[pcap]
enable = none
ENB

for f in sib.conf rr.conf rb.conf; do
    if [ ! -f /etc/srsenb/$f ]; then
        sudo cp /usr/local/share/srsran/$f /etc/srsenb/$f 2>/dev/null || \
        sudo cp /usr/share/srsran/$f /etc/srsenb/$f 2>/dev/null || \
        echo "WARN: $f not found"
    fi
done

sudo sysctl -w net.core.rmem_max=24862979
sudo sysctl -w net.core.wmem_max=24862979

echo "[gnb2] Config ready. Start with: sudo srsenb /etc/srsenb/enb.conf"
