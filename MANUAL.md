# OpenRAN POWDER Testbed — Complete Setup & Load-Balancing Manual

> **Stack:** Open5GS EPC · srsRAN 4G ZMQ · 1 Core · 2 gNBs · 20 UEs · Throughput-triggered handover

---

## Topology

| ID | Node | IP | Role |
|----|------|----|------|
| core | pc811 | `10.10.1.1` | Open5GS MME · SGW-C/U · SMF · UPF · HSS · PCRF |
| gnb1 | pc818 | `10.10.1.2` | srsRAN srsenb — UE 1–10 (+ UE11 initially) |
| gnb2 | pc802 | `10.10.1.3` | srsRAN srsenb — UE 11–20 (after handover) |
| uehost1 | pc808 | `10.10.1.4` | srsue — UE 1–10, netns ue1–ue10 |
| uehost2 | pc801 | `10.10.1.5` | srsue — UE 11–20, netns ue11–ue20 |

---

## ZMQ Port Map

| UE | gNB host | gNB TX REP (binds) | UE TX REP (binds) | gNB conf | UE conf |
|----|----------|--------------------|-------------------|----------|---------|
| UE 1 | gNB1 | `*:2010` | `pc808:2011` | enb_ue1.conf | ue1.conf |
| UE 2 | gNB1 | `*:2020` | `pc808:2021` | enb_ue2.conf | ue2.conf |
| UE 3–10 | gNB1 | `*:20N0` | `pc808:20N1` | enb_ueN.conf | ueN.conf |
| **UE 11 (phase 1)** | **gNB1** | `*:2110` | `pc801:2111` | **enb_ue11.conf** | **ue11_gnb1.conf** |
| **UE 11 (phase 2)** | **gNB2** | `*:3010` | `pc801:3011` | **enb_ue1.conf** | **ue11.conf** |
| UE 12–20 | gNB2 | `*:30J0` | `pc801:30J1` | enb_ue(N-10).conf | ueN.conf |

> **Port formula — gNB1:** UE N → gNB TX `20N0`, UE TX `20N1`
> **Port formula — gNB2:** UE N (J = N−10) → gNB TX `30J0`, UE TX `30J1`

---

## Load-Balance Flow

```
BEFORE trigger:
  gNB1 (pc818): UE1 … UE10 + UE11   ← UE11 starts here
  gNB2 (pc802): (idle)

AFTER trigger (DL > 5 Mbps sustained for 3 polls):
  gNB1 (pc818): UE1 … UE10
  gNB2 (pc802): UE11 … UE20         ← UE11 migrated, 12–20 added
```

---

## Config Quick Reference

| Parameter | Value |
|-----------|-------|
| PLMN | MCC=999, MNC=70 |
| TAC | 1 |
| dl_earfcn | 3350 |
| n_prb | 50 |
| base_srate | 11.52e6 |
| UE release | **8** (`[rrc]` section) |
| rrc_inactivity_timer | **1073741823** |
| gNB1 PCI | 1 |
| gNB2 PCI | **2** |
| UE PDN subnet | 10.45.0.0/16 via ogstun |
| IMSI range | 999700000000001 – 999700000000020 |
| K | `00112233445566778899aabbccddeeff` |
| OPC | `63bfa50ee6523365ff14c1f45f88737d` |

---

## Clean Slate — Kill Everything First

Run in order: **uehost2 → uehost1 → gnb2 → gnb1** (leave core running).

### uehost2 (pc801)

```bash
ssh <user>@pc801.emulab.net
sudo pkill -9 srsue
sleep 2
ps aux | grep srsue | grep -v grep   # should be empty
```

### uehost1 (pc808)

```bash
ssh <user>@pc808.emulab.net
sudo pkill -9 srsue
sleep 2
ps aux | grep srsue | grep -v grep
```

### gnb2 (pc802)

```bash
ssh <user>@pc802.emulab.net
sudo pkill -9 srsenb
sleep 2
ss -tnlp | grep -E "30[0-9][0-9]"   # should be empty
```

### gnb1 (pc818)

```bash
ssh <user>@pc818.emulab.net
sudo pkill -9 srsenb
sleep 2
ss -tnlp | grep -E "20[0-9][0-9]"   # should be empty
```

---

## STEP 1 — Start Open5GS Core (pc811)

```bash
ssh <user>@pc811.emulab.net

# Start (or restart) required 4G services
sudo systemctl restart open5gs-mmed
sudo systemctl restart open5gs-sgwcd
sudo systemctl restart open5gs-sgwud
sudo systemctl restart open5gs-smfd
sudo systemctl restart open5gs-upfd
sudo systemctl restart open5gs-hssd
sudo systemctl restart open5gs-pcrfd

# Confirm all active
systemctl is-active open5gs-mmed open5gs-sgwcd open5gs-sgwud \
          open5gs-smfd open5gs-upfd open5gs-hssd open5gs-pcrfd
```

**Expected:** all print `active`

```bash
# Verify ogstun TUN is up with 10.45.0.1/16
ip addr show ogstun | grep "inet 10.45"

# Verify MME is listening on SCTP 36412
sudo netstat -anp | grep 36412
```

**Expected:** `10.45.0.1/16` on ogstun · `LISTEN` on `10.10.1.1:36412`

```bash
# Leave open in a second terminal to watch attach events live
sudo tail -f /var/log/open5gs/mme.log
```

---

## STEP 2 — Start gNB1 for UE1 (pc818)

> ⚠️ **Always start gNB BEFORE the UE.**
> The gNB TX socket is a ZMQ REP that **binds**; the UE RX is a REQ that **connects**.
> Starting UE first causes a permanent ZMQ deadlock.

```bash
ssh <user>@pc818.emulab.net

mkdir -p /tmp/gnb1_logs

# Start gNB1 instance for UE1
sudo srsenb /etc/srsenb/enb_ue1.conf \
  >> /tmp/gnb1_logs/ue1_stdout.log 2>&1 &

# Wait for ZMQ REP socket to bind — critical
sleep 8

# Confirm port 2010 is listening
ss -tnlp | grep 2010
```

**Expected:** `LISTEN 0 100 0.0.0.0:2010`

```bash
# On core — verify MME accepted the S1 connection
grep "eNB-S1 accepted\|Number of eNBs" /var/log/open5gs/mme.log | tail -4
```

**Expected:** `eNB-S1 accepted[10.10.1.2]` · `Number of eNBs is now 1`

---

## STEP 3 — Start UE1 & Verify Attach (pc808)

```bash
ssh <user>@pc808.emulab.net

mkdir -p /tmp/ue_logs

# Start UE1
sudo srsue /etc/srsue/ue1.conf \
  >> /tmp/ue_logs/ue1_stdout.log 2>&1 &

# Watch progress (allow ~15–20 s)
tail -f /tmp/ue_logs/ue1_stdout.log
```

**Expected output sequence:**

```
Found Cell:  Mode=FDD, PCI=1, PRB=50
Found PLMN:  Id=99970, TAC=1
Random Access Transmission: seq=...
RRC Connected
Random Access Complete.  c-rnti=0x46, ta=0
Network attach successful. IP: 10.45.0.X
```

```bash
# Verify TUN interface appeared inside the namespace
ip netns exec ue1 ip addr show
# Expected: tun_srsue1  inet 10.45.0.X/24

# Ping test from UE1 to core
ip netns exec ue1 ping -c 4 10.45.0.1
```

**Expected:** 0% packet loss, RTT ~30–50 ms

---

## STEP 4 — Add UE2 through UE10 (pc818 + pc808)

Repeat the two blocks below for **N = 2, 3, 4 … 10**.
Always start the gNB instance first, wait 8 s, then the UE.

### On gnb1 (pc818) — start gNB1 instance for UE-N

```bash
ssh <user>@pc818.emulab.net

N=2   # change to 3, 4, 5, 6, 7, 8, 9, 10

sudo srsenb /etc/srsenb/enb_ue${N}.conf \
  >> /tmp/gnb1_logs/ue${N}_stdout.log 2>&1 &

sleep 8

# Verify port bound  (formula: 20N0 — e.g. 2020 for N=2)
PORT=$((N * 10 + 2000))
ss -tnlp | grep $PORT
```

### On uehost1 (pc808) — start UE-N

```bash
ssh <user>@pc808.emulab.net

N=2   # match the gNB instance above

sudo srsue /etc/srsue/ue${N}.conf \
  >> /tmp/ue_logs/ue${N}_stdout.log 2>&1 &

sleep 20
tail -5 /tmp/ue_logs/ue${N}_stdout.log

# Verify TUN in namespace
ip netns exec ue${N} ip addr | grep "inet 10.45"
```

### Quick status check — all UE1–10

```bash
# Run on uehost1 (pc808)
for N in $(seq 1 10); do
  IP=$(ip netns exec ue${N} ip addr 2>/dev/null | grep "inet 10.45" | awk '{print $2}')
  echo "UE${N}: ${IP:-NOT ATTACHED}"
done
```

---

## STEP 5 — Start gNB1 Instance for UE11 (load-balance phase 1) (pc818)

UE11 **starts on gNB1** so the load-balancer can measure its throughput before migrating it to gNB2.

```bash
ssh <user>@pc818.emulab.net

# enb_ue11.conf: enb_id=0x00b, TX port 2110, expects UE RX from pc801:2111
sudo srsenb /etc/srsenb/enb_ue11.conf \
  >> /tmp/gnb1_logs/ue11_stdout.log 2>&1 &

sleep 8

# Verify port 2110 is listening
ss -tnlp | grep 2110
```

**Expected:** `LISTEN 0 100 0.0.0.0:2110`

---

## STEP 6 — Start UE11 Pointing at gNB1 (pc801)

```bash
ssh <user>@pc801.emulab.net

mkdir -p /tmp/ue_logs

# ue11_gnb1.conf sets rx_port=tcp://10.10.1.2:2110  (gNB1)
sudo srsue /etc/srsue/ue11_gnb1.conf \
  >> /tmp/ue_logs/ue11_gnb1_stdout.log 2>&1 &

sleep 20
tail -10 /tmp/ue_logs/ue11_gnb1_stdout.log
```

**Expected:** `Network attach successful. IP: 10.45.0.X`

```bash
ip netns exec ue11 ip addr | grep "inet 10.45"
ip netns exec ue11 ping -c 3 10.45.0.1
```

---

## STEP 7 — Generate Throughput on UE11 to Trigger Load-Balancer

The load-balancer threshold is **5 Mbps DL** sustained for **3 consecutive 5-second polls**.

### On core (pc811) — start iperf3 server

```bash
ssh <user>@pc811.emulab.net
iperf3 -s -B 10.45.0.1 -p 5201 &
```

### On uehost2 (pc801) — drive DL traffic from UE11 namespace

```bash
ssh <user>@pc801.emulab.net

# 60-second DL test:  -R = reverse (server→UE),  -b 10M = 10 Mbps target
sudo ip netns exec ue11 iperf3 \
  -c 10.45.0.1 -p 5201 -t 60 -R -b 10M
```

### Watch DL throughput rising on gNB1 metrics CSV

```bash
ssh <user>@pc818.emulab.net
# col 1=TTI, col 2=nof_ues, col 11=dl_brate Mbps
watch -n2 "tail -1 /tmp/gnb1_ue11_metrics.csv | cut -d';' -f1,2,11"
```

---

## STEP 8 — Automated: Run loadbalance.sh

The script is at [`configs/loadbalance.sh`](configs/loadbalance.sh).
Run it from any machine that has SSH key access to all 5 nodes.

```bash
# Syntax
bash configs/loadbalance.sh [threshold_mbps] [poll_sec] [trigger_count]

# Example — trigger at 5 Mbps, poll every 5 s, fire after 3 consecutive hits
bash configs/loadbalance.sh 5 5 3
```

**Sample output:**

```
[08:22:10] UE-11 DL throughput on gNB1: 7.42 Mbps (threshold: 5, count: 1/3)
[08:22:15] UE-11 DL throughput on gNB1: 8.11 Mbps (threshold: 5, count: 2/3)
[08:22:20] UE-11 DL throughput on gNB1: 7.88 Mbps (threshold: 5, count: 3/3)
[08:22:20] TRIGGER: gNB1 UE-11 DL > 5 Mbps for 3 polls.
[08:22:20] Starting migration: UE-11 → gNB2, then UE-12..20 → gNB2
[08:22:20] Stopping gNB1 instance for UE-11 (port 2110)...
[08:22:28] gNB2-UE11 started. Waiting 8 s for ZMQ REP socket to bind...
[08:22:36] UE-11 restarted on gNB2.
[08:22:51] ✓ UE-11 attached on gNB2. IP: 10.45.0.X/24
[08:22:51] Load balancing complete. UE 11-20 now on gNB2.
```

---

## STEP 9 — Manual Migration of UE11 to gNB2 (pc818 → pc802 → pc801)

Use this if you want to trigger the handover without the script.

### 9a — Stop gNB1 instance for UE11 (pc818)

```bash
ssh <user>@pc818.emulab.net

# Kill only the UE11 gNB1 instance (leaves UE1–10 running)
sudo pkill -f "srsenb /etc/srsenb/enb_ue11.conf"
sleep 3

# Confirm port 2110 is now free
ss -tnlp | grep 2110   # should return nothing
```

### 9b — Start gNB2 instance for UE11 (pc802)

```bash
ssh <user>@pc802.emulab.net

mkdir -p /tmp/gnb2_logs

# On gNB2, enb_ue1.conf is the first slot (serves UE11).
# It binds TX port 3010, expects UE RX from pc801:3011.
sudo srsenb /etc/srsenb/enb_ue1.conf \
  >> /tmp/gnb2_logs/ue11_stdout.log 2>&1 &

# CRITICAL: wait for REP socket to bind before starting UE
sleep 8

ss -tnlp | grep 3010
```

**Expected:** `LISTEN 0 100 0.0.0.0:3010`

```bash
# On core — verify MME accepted gNB2 S1 connection
ssh <user>@pc811.emulab.net
grep "eNB-S1 accepted\[10.10.1.3\]" /var/log/open5gs/mme.log | tail -3
```

### 9c — Stop UE11 (gNB1 variant), restart pointing at gNB2 (pc801)

```bash
ssh <user>@pc801.emulab.net

# Stop UE11 which was pointing at gNB1
sudo pkill -f "srsue /etc/srsue/ue11_gnb1.conf"
sleep 3

# Restart using ue11.conf which has rx_port=tcp://10.10.1.3:3010 (gNB2)
sudo srsue /etc/srsue/ue11.conf \
  >> /tmp/ue_logs/ue11_gnb2_stdout.log 2>&1 &

sleep 20
tail -10 /tmp/ue_logs/ue11_gnb2_stdout.log
```

**Expected:** `Network attach successful. IP: 10.45.0.X`

```bash
ip netns exec ue11 ip addr | grep "inet 10.45"
ip netns exec ue11 ping -c 4 10.45.0.1
```

---

## STEP 10 — Add UE12 through UE20 to gNB2 (pc802 + pc801)

Repeat for **N = 12, 13 … 20**. The gNB2 config index is **J = N − 10**
(UE12 → enb_ue2.conf, UE13 → enb_ue3.conf … UE20 → enb_ue10.conf).

### On gnb2 (pc802) — start gNB2 instance for UE-N

```bash
ssh <user>@pc802.emulab.net

N=12   # change to 13..20
J=$((N - 10))

sudo srsenb /etc/srsenb/enb_ue${J}.conf \
  >> /tmp/gnb2_logs/ue${N}_stdout.log 2>&1 &

sleep 8

# Verify port bound  (formula: 30J0 — e.g. 3020 for J=2/N=12)
PORT=$((J * 10 + 3000))
ss -tnlp | grep $PORT
```

> **Port table — gNB2**
>
> | UE | J | gNB TX | UE TX |
> |----|---|--------|-------|
> | 12 | 2 | 3020 | 3021 |
> | 13 | 3 | 3030 | 3031 |
> | 14 | 4 | 3040 | 3041 |
> | 15 | 5 | 3050 | 3051 |
> | 16 | 6 | 3060 | 3061 |
> | 17 | 7 | 3070 | 3071 |
> | 18 | 8 | 3080 | 3081 |
> | 19 | 9 | 3090 | 3091 |
> | 20 | 10 | 3100 | 3101 |

### On uehost2 (pc801) — start UE-N

```bash
ssh <user>@pc801.emulab.net

N=12   # match the gNB instance above

sudo srsue /etc/srsue/ue${N}.conf \
  >> /tmp/ue_logs/ue${N}_stdout.log 2>&1 &

sleep 20
tail -5 /tmp/ue_logs/ue${N}_stdout.log

ip netns exec ue${N} ip addr | grep "inet 10.45"
```

### Quick status check — all UE11–20

```bash
# Run on uehost2 (pc801)
for N in $(seq 11 20); do
  IP=$(ip netns exec ue${N} ip addr 2>/dev/null | grep "inet 10.45" | awk '{print $2}')
  echo "UE${N}: ${IP:-NOT ATTACHED}"
done
```

---

## STEP 11 — Verify All 20 UEs Attached

### Check MME attach log (core pc811)

```bash
ssh <user>@pc811.emulab.net
grep "Attach complete" /var/log/open5gs/mme.log | tail -25
```

**Expected:** 20 lines with `Attach complete` for IMSI `999700000000001` through `999700000000020`

```bash
grep "Number of eNB-UEs is now" /var/log/open5gs/mme.log | tail -5
```

### Ping test — UE1–10 (uehost1 pc808)

```bash
ssh <user>@pc808.emulab.net
for N in $(seq 1 10); do
  RESULT=$(ip netns exec ue${N} ping -c 2 -W 2 10.45.0.1 2>/dev/null \
    | grep -oP '\d+ received' | head -1)
  echo "UE${N}: ${RESULT:-FAIL}"
done
```

**Expected:** each UE prints `2 received`

### Ping test — UE11–20 (uehost2 pc801)

```bash
ssh <user>@pc801.emulab.net
for N in $(seq 11 20); do
  RESULT=$(ip netns exec ue${N} ping -c 2 -W 2 10.45.0.1 2>/dev/null \
    | grep -oP '\d+ received' | head -1)
  echo "UE${N}: ${RESULT:-FAIL}"
done
```

---

## Log Locations

| Node | Log file | What it shows |
|------|----------|---------------|
| core pc811 | `/var/log/open5gs/mme.log` | S1-Setup, Attach request/complete, bearer setup |
| core pc811 | `/var/log/open5gs/sgwc.log` | GTP-C session create/modify |
| core pc811 | `/var/log/open5gs/upf.log` | UE PDN sessions, IP assignment |
| gnb1 pc818 | `/tmp/gnb1_logs/ueN_stdout.log` | PHY, RLC, S1AP, GTP events per UE |
| gnb1 pc818 | `/tmp/gnb1_ueN_metrics.csv` | Per-TTI metrics — col 2=nof_ues, col 11=dl_brate Mbps |
| gnb2 pc802 | `/tmp/gnb2_logs/ueN_stdout.log` | gNB2 events per UE |
| uehost1 pc808 | `/tmp/ue_logs/ueN_stdout.log` | Cell search, RACH, attach, IP assignment |
| uehost2 pc801 | `/tmp/ue_logs/ueN_stdout.log` | Same for UE 11–20 |

### Live monitoring commands

```bash
# Core MME live
ssh <user>@pc811.emulab.net "sudo tail -f /var/log/open5gs/mme.log"

# gNB1 UE1 live
ssh <user>@pc818.emulab.net "tail -f /tmp/gnb1_logs/ue1_stdout.log"

# UE1 live
ssh <user>@pc808.emulab.net "tail -f /tmp/ue_logs/ue1_stdout.log"

# gNB1 UE11 DL throughput (col 11)
ssh <user>@pc818.emulab.net \
  "watch -n1 'tail -3 /tmp/gnb1_ue11_metrics.csv | cut -d\";\" -f1,2,11'"
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| UE stuck at "Attaching UE…" — only 3 log lines | ZMQ deadlock — gNB not started before UE connected | Kill UE, kill gNB, restart gNB, wait 8 s, then start UE |
| gNB crashes on first RACH (assert in rrc_inactivity_timer) | Value too large (was `3600000` on gNB2) | Use `rrc_inactivity_timer = 1073741823` ✅ fixed |
| UE attaches but ping fails / "Service Request mo-Data" loop | `release = 15` → "Error packing EUTRA capabilities" — DRB never set up | Use `release = 8` in `[rrc]` ✅ fixed |
| TUN interface not visible in netns after attach | Missing `netns = ueN` in `[gw]` section | Add `netns = ueN` to `[gw]` block ✅ fixed |
| `Address already in use` on ZMQ port | Previous srsenb/srsue still holding the socket | `sudo pkill -9 srsenb` or `srsue`, then `sleep 3` |
| gNB2 UEs attach to gNB1 cell (wrong gNB) | Both rr.conf had `pci = 1` | gNB2 rr.conf now has `pci = 2` ✅ fixed |
| MME says "eNB-S1 connection refused!!!" every 2 min | srsenb process died / SCTP path lost | Check gNB `_stdout.log` for crash reason; restart gNB then UE |
| UE11 doesn't attach after migration to gNB2 | Old UE11 process still running, or gNB2 REP not bound yet | `sudo pkill -9 srsue` on pc801, confirm port 3010 LISTEN, restart UE11 |

### Quick diagnostics one-liners

```bash
# How many UEs have attached (MME)
grep "Attach complete" /var/log/open5gs/mme.log | wc -l

# Which gNBs are currently connected to MME
grep "Number of eNBs" /var/log/open5gs/mme.log | tail -5

# All ZMQ ports listening on gnb1
ssh <user>@pc818.emulab.net "ss -tnlp | grep srsenb"

# All UE IPs on uehost1
ssh <user>@pc808.emulab.net \
  "for n in \$(seq 1 10); do ip netns exec ue\$n ip addr 2>/dev/null | grep 'inet 10.45'; done"

# UE11 current gNB — which port did it connect to?
ssh <user>@pc801.emulab.net "ss -tn | grep -E '2110|3010'"
```
