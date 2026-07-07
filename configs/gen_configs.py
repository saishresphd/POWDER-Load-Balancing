#!/usr/bin/env python3
"""
Generate all srsenb and srsue config files for:
  gNB1 (pc818, 10.10.1.2): serves UE1-10 from uehost1 (10.10.1.4)
  gNB2 (pc802, 10.10.1.3): serves UE11-20 from uehost2 (10.10.1.5)

ZMQ port design:
  UE index i (1-10) on gNB1:
    srsenb tx_port = tcp://*:2{i:02d}0   (e.g. UE1=2010, UE2=2020 ... UE10=2100)
    srsenb rx_port = tcp://10.10.1.4:2{i:02d}1
    srsue  tx_port = tcp://*:2{i:02d}1
    srsue  rx_port = tcp://10.10.1.2:2{i:02d}0

  UE index i (11-20), local j=i-10 (1-10) on gNB2:
    srsenb tx_port = tcp://*:3{j:02d}0
    srsenb rx_port = tcp://10.10.1.5:3{j:02d}1
    srsue  tx_port = tcp://*:3{j:02d}1
    srsue  rx_port = tcp://10.10.1.3:3{j:02d}0

PLMN: MCC=999, MNC=70, TAC=1, dl_earfcn=3350, n_prb=50, base_srate=11.52e6
Using n_prb=50 (10 MHz) + base_srate=11.52e6 for lower CPU load on ZMQ simulation
"""
import os

# ─── Parameters ───────────────────────────────────────────────────────────────
MCC         = "999"
MNC         = "70"
TAC         = 1
DL_EARFCN   = 3350
N_PRB       = 50          # 10 MHz — less CPU than 100 PRB on ZMQ sim
BASE_SRATE  = "11.52e6"   # must match n_prb=50
K           = "00112233445566778899aabbccddeeff"
OPC         = "63bfa50ee6523365ff14c1f45f88737d"
MME_ADDR    = "10.10.1.1"
GNB1_IP     = "10.10.1.2"
GNB2_IP     = "10.10.1.3"
UH1_IP      = "10.10.1.4"
UH2_IP      = "10.10.1.5"

SIB_CONF    = "/etc/srsenb/sib.conf"
RR_CONF     = "/etc/srsenb/rr.conf"
RB_CONF     = "/etc/srsenb/rb.conf"

# ─── ENB config template ──────────────────────────────────────────────────────
ENB_TEMPLATE = """\
[enb]
enb_id = 0x{enb_id:03X}
mcc = {mcc}
mnc = {mnc}
mme_addr = {mme_addr}
gtp_bind_addr = {gnb_ip}
s1c_bind_addr = {gnb_ip}
s1c_bind_port = 0
n_prb = {n_prb}

[enb_files]
sib_config = {sib_conf}
rr_config  = {rr_conf}
rb_config  = {rb_conf}

[rf]
dl_earfcn = {dl_earfcn}
tx_gain   = 80
rx_gain   = 40
device_name = zmq
device_args = fail_on_disconnect=true,tx_port={tx_port},rx_port={rx_port},id=enb{ue_idx},base_srate={base_srate}

[expert]
rrc_inactivity_timer = 1073741823
metrics_csv_enable   = true
metrics_csv_filename = /tmp/gnb{gnb_num}_ue{ue_idx}_metrics.csv
metrics_period_secs  = 1

[log]
all_level    = info
filename     = /tmp/gnb{gnb_num}_ue{ue_idx}.log
file_max_size = -1

[pcap]
enable = false
"""

# ─── UE config template ───────────────────────────────────────────────────────
UE_TEMPLATE = """\
[rf]
freq_offset  = 0
tx_gain      = 80
rx_gain      = 40
nof_antennas = 1
device_name  = zmq
device_args  = fail_on_disconnect=true,tx_port={tx_port},rx_port={rx_port},id=ue{ue_idx},base_srate={base_srate}

[rat.eutra]
dl_earfcn    = {dl_earfcn}
nof_carriers = 1

[usim]
mode = soft
algo = milenage
opc  = {opc}
k    = {k}
imsi = {imsi}
imei = 35349006{ue_idx:07d}

[rrc]
release     = 8
ue_category = 4

[nas]
apn          = internet
apn_protocol = ipv4

[gw]
netns      = ue{ue_idx}
ip_devname = tun_srsue{ue_idx}
ip_netmask = 255.255.255.0

[log]
all_level    = info
filename     = /tmp/ue{ue_idx}.log
file_max_size = -1
"""

# ─── rr.conf (same for both gNBs) ─────────────────────────────────────────────
RR_CONF_CONTENT = """\
mac_cnfg =
{
  phr_cnfg =
  {
    dl_pathloss_change = "dB3";
    periodic_phr_timer = 50;
    prohibit_phr_timer = 0;
  };
  ulsch_cnfg =
  {
    max_harq_tx        = 4;
    periodic_bsr_timer = 20;
    retx_bsr_timer     = 320;
  };
  time_alignment_timer = -1;
};

phy_cnfg =
{
  phich_cnfg =
  {
    duration  = "Normal";
    resources = "1/6";
  };
  pusch_cnfg_ded =
  {
    beta_offset_ack_idx = 6;
    beta_offset_ri_idx  = 6;
    beta_offset_cqi_idx = 6;
  };
  sched_request_cnfg =
  {
    dsr_trans_max = 64;
    period        = 20;
    nof_prb       = 1;
  };
  cqi_report_cnfg =
  {
    mode              = "periodic";
    simultaneousAckCQI = true;
    period            = 40;
    m_ri              = 8;
  };
};

cell_list =
(
  {
    cell_id    = 0x01;
    tac        = 0x0001;
    pci        = 1;
    dl_earfcn  = 3350;
    ho_active  = false;
    scell_list = ();
    meas_cell_list = ();
    meas_report_desc = ();
    meas_quant_desc = { rsrq_config = 4; rsrp_config = 4; };
  }
);

nr_cell_list = ();
"""

# ─── Generate files ───────────────────────────────────────────────────────────
os.makedirs("configs/gnb1", exist_ok=True)
os.makedirs("configs/gnb2", exist_ok=True)
os.makedirs("configs/ues",  exist_ok=True)

# Write shared rr.conf for both gNBs
for d in ["configs/gnb1", "configs/gnb2"]:
    with open(f"{d}/rr.conf", "w") as f:
        f.write(RR_CONF_CONTENT)

# GNB1: UE1-10, enb_id 0x001-0x00A
for i in range(1, 11):
    tx_port = f"tcp://*:2{i:02d}0"
    rx_port = f"tcp://{UH1_IP}:2{i:02d}1"
    cfg = ENB_TEMPLATE.format(
        enb_id=i, mcc=MCC, mnc=MNC, mme_addr=MME_ADDR, gnb_ip=GNB1_IP,
        n_prb=N_PRB, dl_earfcn=DL_EARFCN, base_srate=BASE_SRATE,
        tx_port=tx_port, rx_port=rx_port,
        ue_idx=i, gnb_num=1,
        sib_conf=SIB_CONF, rr_conf=RR_CONF, rb_conf=RB_CONF
    )
    with open(f"configs/gnb1/enb_ue{i}.conf", "w") as f:
        f.write(cfg)
    print(f"gnb1/enb_ue{i}.conf: tx={tx_port} rx={rx_port}")

# GNB2: UE11-20, enb_id 0x00B-0x014, local j=1-10
for i in range(11, 21):
    j = i - 10
    tx_port = f"tcp://*:3{j:02d}0"
    rx_port = f"tcp://{UH2_IP}:3{j:02d}1"
    cfg = ENB_TEMPLATE.format(
        enb_id=0x10+j, mcc=MCC, mnc=MNC, mme_addr=MME_ADDR, gnb_ip=GNB2_IP,
        n_prb=N_PRB, dl_earfcn=DL_EARFCN, base_srate=BASE_SRATE,
        tx_port=tx_port, rx_port=rx_port,
        ue_idx=i, gnb_num=2,
        sib_conf=SIB_CONF, rr_conf=RR_CONF, rb_conf=RB_CONF
    )
    with open(f"configs/gnb2/enb_ue{j}.conf", "w") as f:
        f.write(cfg)
    print(f"gnb2/enb_ue{j}.conf (UE{i}): tx={tx_port} rx={rx_port}")

# UE1-10 on uehost1 → connect to gNB1
for i in range(1, 11):
    imsi = f"99970000000{i:04d}"
    tx_port = f"tcp://*:2{i:02d}1"
    rx_port = f"tcp://{GNB1_IP}:2{i:02d}0"
    cfg = UE_TEMPLATE.format(
        ue_idx=i, dl_earfcn=DL_EARFCN, base_srate=BASE_SRATE,
        tx_port=tx_port, rx_port=rx_port,
        k=K, opc=OPC, imsi=imsi
    )
    with open(f"configs/ues/ue{i}.conf", "w") as f:
        f.write(cfg)
    print(f"ues/ue{i}.conf: imsi={imsi} tx={tx_port} rx={rx_port}")

# UE11-20 on uehost2 → connect to gNB2
for i in range(11, 21):
    j = i - 10
    imsi = f"99970000000{i:04d}"
    tx_port = f"tcp://*:3{j:02d}1"
    rx_port = f"tcp://{GNB2_IP}:3{j:02d}0"
    cfg = UE_TEMPLATE.format(
        ue_idx=i, dl_earfcn=DL_EARFCN, base_srate=BASE_SRATE,
        tx_port=tx_port, rx_port=rx_port,
        k=K, opc=OPC, imsi=imsi
    )
    with open(f"configs/ues/ue{i}.conf", "w") as f:
        f.write(cfg)
    print(f"ues/ue{i}.conf: imsi={imsi} tx={tx_port} rx={rx_port}")

print("\nAll configs generated.")
