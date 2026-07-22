#!/usr/bin/env python3
"""
gen_configs.py — Generate srsenb and srsue configs for the 110-UE testbed.

TOPOLOGY (SPLIT — 50+50 to avoid OOM on each gNB node)
  gNB1  pc818  10.10.1.2   50 srsenb slots  (UE1–50)
    UE traffic from uehost1 (10.10.1.4)

  gNB2  pc802  10.10.1.3   60 srsenb slots
    Slots  51–100: base-load UEs from uehost1 (10.10.1.4)
    Slots 101–110: LB-candidate UEs from uehost2 (10.10.1.5), initially on gNB1
                   post-handover target also on gNB2

  core  pc811  10.10.1.1   Open5GS EPC (MME/SGW/UPF/HSS)
  uehost1  pc808  10.10.1.4   UE1–100  (netns ue1–ue100)
  uehost2  pc801  10.10.1.5   UE101–110 (netns ue101–ue110)

ZMQ PORTS
  UE1–50  on gNB1 / uehost1:
    gNB1 tx REP  tcp://*:4NNN0    NNN = zero-padded UE index  e.g. UE1=40010  UE50=40500
    gNB1 rx REQ  tcp://10.10.1.4:4NNN1
    UE   tx REP  tcp://*:4NNN1
    UE   rx REQ  tcp://10.10.1.2:4NNN0

  UE51–100 on gNB2 / uehost2  (j = i-50, 1–50):
    gNB2 tx REP  tcp://*:5JJJ0    e.g. UE51=50010  UE100=50500
    gNB2 rx REQ  tcp://10.10.1.5:5JJJ1
    UE   tx REP  tcp://*:5JJJ1
    UE   rx REQ  tcp://10.10.1.3:5JJJ0

  UE101–110 on gNB1 / uehost2  (initial LB phase, j = i-100, 1–10):
    gNB1 tx REP  tcp://*:5JJJ0    e.g. UE101=50010  UE110=50100
    gNB1 rx REQ  tcp://10.10.1.5:5JJJ1
    UE   tx REP  tcp://*:5JJJ1
    UE   rx REQ  tcp://10.10.1.2:5JJJ0

  UE101–110 on gNB2 / uehost2  (post-handover, j = i-100, 1–10):
    gNB2 tx REP  tcp://*:6JJJ0    e.g. UE101=60010  UE110=60100
    gNB2 rx REQ  tcp://10.10.1.5:6JJJ1
    UE   tx REP  tcp://*:6JJJ1
    UE   rx REQ  tcp://10.10.1.3:6JJJ0

GTP BIND ADDRESSES  (one unique IP per srsenb instance to avoid port-2152 clashes)
  gNB1 UE1     : 10.10.1.2          (node primary)
  gNB1 UE2–50  : 10.10.1.{98+i}    → .100–.148
  gNB1 LB UE101–110: 10.10.1.{199+j} → .200–.209
  gNB2 UE51    : 10.10.1.3          (node primary)
  gNB2 UE52–100: 10.10.1.{148+i-51} = 10.10.1.{149+i-52} → .149–.197
  gNB2 LB UE101–110: 10.10.1.{209+j} → .210–.219

SUBSCRIBER IMSI
  UE i → 99970{i:010d}  (15 digits)
  e.g. UE1=999700000000001  UE100=999700000000100  UE110=999700000000110

NOTE: Delete a file manually and re-run to regenerate it (additive script).
"""
import os
import glob as _glob

# ─── Topology constants ────────────────────────────────────────────────────────
MCC        = "999"
MNC        = "70"
DL_EARFCN  = 3350
N_PRB      = 50           # 10 MHz — lower CPU on ZMQ simulation
BASE_SRATE = "11.52e6"    # must match n_prb = 50
K          = "00112233445566778899aabbccddeeff"
OPC        = "63bfa50ee6523365ff14c1f45f88737d"
MME_ADDR   = "10.10.1.1"
GNB1_IP    = "10.10.1.2"
GNB2_IP    = "10.10.1.3"
UH1_IP     = "10.10.1.4"   # uehost1  UE1–100
UH2_IP     = "10.10.1.5"   # uehost2  UE101–110

SIB_CONF   = "/etc/srsenb/sib.conf"
RR_CONF    = "/etc/srsenb/rr.conf"
RB_CONF    = "/etc/srsenb/rb.conf"

# ─── Address helpers ───────────────────────────────────────────────────────────

def gtp_gnb1_base(i):
    """GTP/S1C bind addr for gNB1 base slot i (1–50).
    i=1  → 10.10.1.2  (primary)
    i=2  → 10.10.1.100
    ...
    i=50 → 10.10.1.148
    """
    return "10.10.1.2" if i == 1 else f"10.10.1.{98 + i}"

def gtp_gnb2_base(i):
    """GTP/S1C bind addr for gNB2 base slot i (51–100).
    i=51  → 10.10.1.3  (primary)
    i=52  → 10.10.1.149
    ...
    i=100 → 10.10.1.197
    """
    return "10.10.1.3" if i == 51 else f"10.10.1.{97 + i}"

def gtp_gnb1_lb(j):
    """GTP/S1C bind addr for gNB1 LB slot j (1–10).
    j=1 → 10.10.1.200 … j=10 → 10.10.1.209
    """
    return f"10.10.1.{199 + j}"

def gtp_gnb2_lb(j):
    """GTP/S1C bind addr for gNB2 LB target slot j (1–10).
    j=1 → 10.10.1.210 … j=10 → 10.10.1.219
    """
    return f"10.10.1.{209 + j}"

def make_imsi(i):
    """15-digit IMSI: 99970 + i zero-padded to 10 digits."""
    return f"99970{i:010d}"

# ─── Config templates ──────────────────────────────────────────────────────────

ENB_TMPL = """\
[enb]
enb_id = 0x{enb_id:03X}
mcc = {mcc}
mnc = {mnc}
mme_addr = {mme_addr}
gtp_bind_addr = {gtp_addr}
s1c_bind_addr = {s1c_addr}
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
device_args = fail_on_disconnect=true,tx_port={tx_port},rx_port={rx_port},id={zmq_id},base_srate={base_srate}

[expert]
rrc_inactivity_timer = 1073741823
metrics_csv_enable   = true
metrics_csv_filename = {metrics_csv}
metrics_period_secs  = 1

[log]
all_level    = info
filename     = {log_file}
file_max_size = -1

[pcap]
enable = false
"""

UE_TMPL = """\
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

# rr.conf for gNB1 (PCI=1) and gNB2 (PCI=2)
RR_GNB1 = """\
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

RR_GNB2 = RR_GNB1.replace(
    "cell_id    = 0x01;", "cell_id    = 0x02;"
).replace(
    "pci        = 1;",    "pci        = 2;"
)

# ─── Helper: write file only if it does not already exist ─────────────────────

def write_if_new(path, content):
    if os.path.exists(path):
        return False   # skip — preserve existing working config
    with open(path, "w") as f:
        f.write(content)
    return True

# ─── Ensure directories exist ─────────────────────────────────────────────────
os.makedirs("configs/gnb1", exist_ok=True)
os.makedirs("configs/gnb2", exist_ok=True)
os.makedirs("configs/ues",  exist_ok=True)

# ─── rr.conf (write only if missing) ─────────────────────────────────────────
write_if_new("configs/gnb1/rr.conf", RR_GNB1)
write_if_new("configs/gnb2/rr.conf", RR_GNB2)

# ─── gNB1: slots 1–50  (base-load UEs, traffic from uehost1) ──────────────────
created = skipped = 0
for i in range(1, 51):
    path = f"configs/gnb1/enb_ue{i}.conf"
    content = ENB_TMPL.format(
        enb_id      = i,
        mcc=MCC, mnc=MNC, mme_addr=MME_ADDR,
        gtp_addr    = gtp_gnb1_base(i),
        s1c_addr    = gtp_gnb1_base(i),   # gNB1: s1c = same as gtp alias
        n_prb=N_PRB, dl_earfcn=DL_EARFCN, base_srate=BASE_SRATE,
        tx_port     = f"tcp://*:4{i:03d}0",
        rx_port     = f"tcp://{UH1_IP}:4{i:03d}1",
        zmq_id      = f"enb{i}",
        metrics_csv = f"/tmp/gnb1_ue{i}_metrics.csv",
        log_file    = f"/tmp/gnb1_logs/ue{i}.log",
        sib_conf=SIB_CONF, rr_conf=RR_CONF, rb_conf=RB_CONF,
    )
    if write_if_new(path, content): created += 1
    else: skipped += 1
print(f"gNB1 base  (ue1–50):    {created} created, {skipped} already existed — ports 40010–40500, GTP .2/.100–.148")

# ─── gNB2: slots 51–100  (base-load UEs, traffic from uehost2) ────────────────
created = skipped = 0
for i in range(51, 101):
    j = i - 50              # local index 1–50
    path = f"configs/gnb2/enb_ue{i}.conf"
    content = ENB_TMPL.format(
        enb_id      = 0x300 + i,
        mcc=MCC, mnc=MNC, mme_addr=MME_ADDR,
        gtp_addr    = gtp_gnb2_base(i),
        s1c_addr    = GNB2_IP,             # gNB2: always use primary .3 for S1AP
        n_prb=N_PRB, dl_earfcn=DL_EARFCN, base_srate=BASE_SRATE,
        tx_port     = f"tcp://*:{50000 + j*10}",
        rx_port     = f"tcp://{UH2_IP}:{50000 + j*10 + 1}",
        zmq_id      = f"enb{i}g2",
        metrics_csv = f"/tmp/gnb2_ue{i}_metrics.csv",
        log_file    = f"/tmp/gnb2_logs/ue{i}.log",
        sib_conf=SIB_CONF, rr_conf=RR_CONF, rb_conf=RB_CONF,
    )
    if write_if_new(path, content): created += 1
    else: skipped += 1
print(f"gNB2 base  (ue51–100):  {created} created, {skipped} already existed — ports 50010–50500, GTP .3/.149–.197")

# ─── gNB1: slots 101–110  (LB-candidate UEs, traffic from uehost2) ─────────────
created = skipped = 0
for i in range(101, 111):
    j    = i - 100          # local slot index 1–10
    path = f"configs/gnb1/enb_ue{i}.conf"
    content = ENB_TMPL.format(
        enb_id      = 0x100 + j,
        mcc=MCC, mnc=MNC, mme_addr=MME_ADDR,
        gtp_addr    = gtp_gnb1_lb(j),
        s1c_addr    = gtp_gnb1_lb(j),     # gNB1 LB: s1c = same as gtp alias
        n_prb=N_PRB, dl_earfcn=DL_EARFCN, base_srate=BASE_SRATE,
        tx_port     = f"tcp://*:5{j:03d}0",
        rx_port     = f"tcp://{UH2_IP}:5{j:03d}1",
        zmq_id      = f"enb{i}",
        metrics_csv = f"/tmp/gnb1_ue{i}_metrics.csv",
        log_file    = f"/tmp/gnb1_logs/ue{i}.log",
        sib_conf=SIB_CONF, rr_conf=RR_CONF, rb_conf=RB_CONF,
    )
    if write_if_new(path, content): created += 1
    else: skipped += 1
print(f"gNB1 LB    (ue101–110): {created} created, {skipped} already existed — ports 50010–50100, GTP .200–.209")

# ─── gNB2: slots 101–110  (LB-target UEs, active after handover) ───────────────
created = skipped = 0
for i in range(101, 111):
    j    = i - 100
    path = f"configs/gnb2/enb_ue{i}.conf"
    content = ENB_TMPL.format(
        enb_id      = 0x200 + j,
        mcc=MCC, mnc=MNC, mme_addr=MME_ADDR,
        gtp_addr    = gtp_gnb2_lb(j),
        s1c_addr    = GNB2_IP,             # gNB2 LB: use primary .3 for S1AP
        n_prb=N_PRB, dl_earfcn=DL_EARFCN, base_srate=BASE_SRATE,
        tx_port     = f"tcp://*:6{j:03d}0",
        rx_port     = f"tcp://{UH2_IP}:6{j:03d}1",
        zmq_id      = f"enb{i}g2",
        metrics_csv = f"/tmp/gnb2_ue{i}_metrics.csv",
        log_file    = f"/tmp/gnb2_logs/ue{i}.log",
        sib_conf=SIB_CONF, rr_conf=RR_CONF, rb_conf=RB_CONF,
    )
    if write_if_new(path, content): created += 1
    else: skipped += 1
print(f"gNB2 target (ue101–110): {created} created, {skipped} already existed — ports 60010–60100, GTP .210–.219")

# ─── UE1–50: uehost1, connect to gNB1 ─────────────────────────────────────────
created = skipped = 0
for i in range(1, 51):
    path = f"configs/ues/ue{i}.conf"
    content = UE_TMPL.format(
        ue_idx    = i,
        dl_earfcn = DL_EARFCN, base_srate=BASE_SRATE,
        tx_port   = f"tcp://*:4{i:03d}1",
        rx_port   = f"tcp://{GNB1_IP}:4{i:03d}0",
        k=K, opc=OPC, imsi=make_imsi(i),
    )
    if write_if_new(path, content): created += 1
    else: skipped += 1
print(f"UE base    (ue1–50):    {created} created, {skipped} already existed — → gNB1")

# ─── UE51–100: uehost2 (pc801), connect to gNB2 ──────────────────────────────
created = skipped = 0
for i in range(51, 101):
    j = i - 50              # local index 1–50
    path = f"configs/ues/ue{i}.conf"
    content = UE_TMPL.format(
        ue_idx    = i,
        dl_earfcn = DL_EARFCN, base_srate=BASE_SRATE,
        tx_port   = f"tcp://*:{50000 + j*10 + 1}",
        rx_port   = f"tcp://{GNB2_IP}:{50000 + j*10}",
        k=K, opc=OPC, imsi=make_imsi(i),
    )
    if write_if_new(path, content): created += 1
    else: skipped += 1
print(f"UE base    (ue51–100):  {created} created, {skipped} already existed — → gNB2")

# ─── UE101–110: uehost2, initial variant pointing at gNB1 ─────────────────────
created = skipped = 0
for i in range(101, 111):
    j    = i - 100
    path = f"configs/ues/ue{i}_gnb1.conf"
    content = UE_TMPL.format(
        ue_idx    = i,
        dl_earfcn = DL_EARFCN, base_srate=BASE_SRATE,
        tx_port   = f"tcp://*:5{j:03d}1",
        rx_port   = f"tcp://{GNB1_IP}:5{j:03d}0",
        k=K, opc=OPC, imsi=make_imsi(i),
    )
    if write_if_new(path, content): created += 1
    else: skipped += 1
print(f"UE LB gnb1 (ue101–110): {created} created, {skipped} already existed — → gNB1 (initial)")

# ─── UE101–110: uehost2, post-handover variant pointing at gNB2 ───────────────
created = skipped = 0
for i in range(101, 111):
    j    = i - 100
    path = f"configs/ues/ue{i}.conf"
    content = UE_TMPL.format(
        ue_idx    = i,
        dl_earfcn = DL_EARFCN, base_srate=BASE_SRATE,
        tx_port   = f"tcp://*:6{j:03d}1",
        rx_port   = f"tcp://{GNB2_IP}:6{j:03d}0",
        k=K, opc=OPC, imsi=make_imsi(i),
    )
    if write_if_new(path, content): created += 1
    else: skipped += 1
print(f"UE LB gnb2 (ue101–110): {created} created, {skipped} already existed — → gNB2 (post-HO)")

# ─── Final summary ─────────────────────────────────────────────────────────────
gnb1_n = len(_glob.glob("configs/gnb1/enb_ue*.conf"))
gnb2_n = len(_glob.glob("configs/gnb2/enb_ue*.conf"))
ue_n   = len(_glob.glob("configs/ues/ue*.conf"))

print()
print("=" * 70)
print(f"  gNB1 enb configs : {gnb1_n:3d}  (slots 1–50 base + 101–110 LB)")
print(f"  gNB2 enb configs : {gnb2_n:3d}  (slots 51–100 base + 101–110 LB targets)")
print(f"  UE configs       : {ue_n:3d}  (ue1–50→gNB1, ue51–100→gNB2, ue101–110×2)")
print()
print("  IP aliases required on gNB1 (pc818, enp6s0f3):")
print("    10.10.1.100–148  UE2–50   (49 aliases)")
print("    10.10.1.200–209  UE101–110 LB slots  (10 aliases)")
print()
print("  IP aliases required on gNB2 (pc802, enp6s0f3):")
print("    10.10.1.149–197  UE52–100 (49 aliases)")
print("    10.10.1.210–219  UE101–110 LB targets  (10 aliases)")
print("=" * 70)
