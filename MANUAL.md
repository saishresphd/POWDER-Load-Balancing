# OpenRAN POWDER Testbed — Complete Setup & Load-Balancing Manual

> **Stack:** Open5GS EPC · srsRAN 4G ZMQ · 1 Core · 2 gNBs · **110 UEs** · Throughput + CPU triggered load-balancing handover
>
> **Branch `main`** — working 10-UE baseline |  **Branch `110-ue-scale`** — full 110-UE scale-up

---

## Topology

| ID | Node | IP | Role |
|----|------|----|------|
| core | pc811 | `10.10.1.1` | Open5GS MME · SGW-C/U · SMF · UPF · HSS · PCRF |
| gnb1 | pc818 | `10.10.1.2` | srsRAN srsenb — 110 slots: UE1–100 base + UE101–110 LB (initially) |
| gnb2 | pc802 | `10.10.1.3` | srsRAN srsenb — 10 slots: UE101–110 LB targets (after handover) |
| uehost1 | pc808 | `10.10.1.4` | srsue — UE1–100, netns ue1–ue100 |
| uehost2 | pc801 | `10.10.1.5` | srsue — UE101–110, netns ue101–ue110 |

---

## ZMQ Port Map

### UE1–100 on gNB1 / uehost1

> **Port formula:** UE index `N` (1–100) → gNB TX `4NNN0`, UE TX `4NNN1`  (NNN = N zero-padded to 3 digits)

| UE range | gNB TX REP (binds on pc818) | UE TX REP (binds on pc808) | gNB conf | UE conf |
|----------|-----------------------------|---------------------------|----------|---------|
| UE 1 | `*:40010` | `pc808:40011` | `gnb1/enb_ue1.conf` | `ue1.conf` |
| UE 2 | `*:40020` | `pc808:40021` | `gnb1/enb_ue2.conf` | `ue2.conf` |
| UE 10 | `*:40100` | `pc808:40101` | `gnb1/enb_ue10.conf` | `ue10.conf` |
| UE 50 | `*:40500` | `pc808:40501` | `gnb1/enb_ue50.conf` | `ue50.conf` |
| UE 100 | `*:41000` | `pc808:41001` | `gnb1/enb_ue100.conf` | `ue100.conf` |

### UE101–110 LB candidates — phase 1 (initially on gNB1 / uehost2)

> **Port formula:** `j = N−100` (1–10) → gNB TX `5JJJ0`, UE TX `5JJJ1`

| UE | gNB TX REP (pc818) | UE TX REP (pc801) | gNB conf | UE conf |
|----|---------------------|-------------------|----------|---------|
| UE 101 | `*:50010` | `pc801:50011` | `gnb1/enb_ue101.conf` | `ue101_gnb1.conf` |
| UE 105 | `*:50050` | `pc801:50051` | `gnb1/enb_ue105.conf` | `ue105_gnb1.conf` |
| UE 110 | `*:50100` | `pc801:50101` | `gnb1/enb_ue110.conf` | `ue110_gnb1.conf` |

### UE101–110 LB targets — phase 2 (after handover to gNB2 / uehost2)

> **Port formula:** `j = N−100` (1–10) → gNB TX `6JJJ0`, UE TX `6JJJ1`

| UE | gNB TX REP (pc802) | UE TX REP (pc801) | gNB conf | UE conf |
|----|---------------------|-------------------|----------|---------|
| UE 101 | `*:60010` | `pc801:60011` | `gnb2/enb_ue101.conf` | `ue101.conf` |
| UE 105 | `*:60050` | `pc801:60051` | `gnb2/enb_ue105.conf` | `ue105.conf` |
| UE 110 | `*:60100` | `pc801:60101` | `gnb2/enb_ue110.conf` | `ue110.conf` |

---

## GTP Bind Address Map (Critical — one unique IP per srsenb instance)

Because multiple `srsenb` processes share the same physical host, each must bind GTP-U
(`port 2152`) on a **different IP address**. We use secondary IP aliases on the LAN interface.
The MME learns each alias as a separate eNB S1-U address.

### gNB1 (pc818) — LAN interface `enp6s0f3`

> **Formula — base slots:** UE `i` (1–100) → `10.10.1.2` (i=1) or `10.10.1.{98+i}` (i=2–100)
> **Formula — LB slots:** UE `101+j-1` (j=1–10) → `10.10.1.{199+j}`

| gNB1 slot | Serves | gtp_bind_addr / s1c_bind_addr |
|-----------|--------|-------------------------------|
| enb_ue1.conf | UE 1 | `10.10.1.2` (primary, no alias) |
| enb_ue2.conf | UE 2 | `10.10.1.100` |
| enb_ue3.conf | UE 3 | `10.10.1.101` |
| enb_ue10.conf | UE 10 | `10.10.1.108` |
| enb_ue50.conf | UE 50 | `10.10.1.148` |
| enb_ue100.conf | UE 100 | `10.10.1.198` |
| enb_ue101.conf | UE 101 (LB) | `10.10.1.200` |
| enb_ue105.conf | UE 105 (LB) | `10.10.1.204` |
| enb_ue110.conf | UE 110 (LB) | `10.10.1.209` |

### gNB2 (pc802) — LAN interface `enp6s0f3`

> **Formula — LB targets:** UE `101+j-1` (j=1–10) → `10.10.1.{209+j}`

| gNB2 slot | Serves | gtp_bind_addr / s1c_bind_addr |
|-----------|--------|-------------------------------|
| enb_ue101.conf | UE 101 | `10.10.1.210` |
| enb_ue105.conf | UE 105 | `10.10.1.214` |
| enb_ue110.conf | UE 110 | `10.10.1.219` |

### One-time alias setup (run once per node after every reboot)

Run the script (recommended — handles all ranges automatically):

```bash
bash configs/setup_aliases.sh
```

Or set up manually on each node:

```bash
# ── On gnb1 (pc818) ──────────────────────────────────────────────────────────
ssh <user>@pc818.emulab.net

DEV=enp6s0f3

# UE2–100 base slots: 10.10.1.100–198  (formula: 10.10.1.{98+i} for i=2..100)
for i in $(seq 2 100); do
  sudo ip addr add 10.10.1.$((98 + i))/24 dev $DEV 2>/dev/null || true
done

# UE101–110 LB slots: 10.10.1.200–209  (formula: 10.10.1.{199+j} for j=1..10)
for j in $(seq 1 10); do
  sudo ip addr add 10.10.1.$((199 + j))/24 dev $DEV 2>/dev/null || true
done

# Verify
ip addr show $DEV | grep "inet 10.10.1"
```

```bash
# ── On gnb2 (pc802) ──────────────────────────────────────────────────────────
ssh <user>@pc802.emulab.net

DEV=enp6s0f3

# UE101–110 LB targets: 10.10.1.210–219  (formula: 10.10.1.{209+j} for j=1..10)
for j in $(seq 1 10); do
  sudo ip addr add 10.10.1.$((209 + j))/24 dev $DEV 2>/dev/null || true
done

# Verify
ip addr show $DEV | grep "inet 10.10.1"
```

> ⚠️ **Aliases are lost on reboot.** Re-run `setup_aliases.sh` after every node reboot
> before starting any srsenb processes.

---

## Load-Balance Flow

```
BEFORE trigger:
  gNB1 (pc818): UE1…UE100 (base)  +  UE101…UE110 (LB candidates on gNB1)
  gNB2 (pc802): 10 srsenb LB-target slots running but IDLE (ZMQ REP bound, no UE)

TRIGGER fires when (either condition sustained for 3 consecutive polls):
  • avg DL per UE across UE1–100 < 0.5 Mbps  (throughput dip = congestion)
  • gNB1 CPU load > 80%                        (power-saving / overload)

MIGRATION (one UE at a time, 101→102→…→110):
  For each LB UE N:
    1. Start gNB2 slot N (ZMQ REP binds on 6JJJ0)
    2. Stop  gNB1 slot N
    3. Stop  UE N process on uehost2 (was using ueN_gnb1.conf → gNB1)
    4. Start UE N on uehost2 using ueN.conf (→ gNB2)
    5. Verify attach + ping before migrating next UE

AFTER all 10 migrated:
  gNB1 (pc818): UE1…UE100
  gNB2 (pc802): UE101…UE110
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
| IMSI range | `999700000000001` – `999700000000110` |
| K | `00112233445566778899aabbccddeeff` |
| OPC | `63bfa50ee6523365ff14c1f45f88737d` |

---

## Clean Slate — Kill Everything First

Run in order: **uehost2 → uehost1 → gnb2 → gnb1** (leave core running).

> ⚠️ `pkill` on these nodes only accepts one argument. Use `kill -9 <PID>` for precision,
> or `fuser -k <port>/tcp` to free a specific ZMQ port.

### uehost2 (pc801)

```bash
ssh <user>@pc801.emulab.net

# Kill all srsue by PID (pkill -9 srsue works on some nodes; use explicit PIDs if not)
for PID in $(ps aux | grep '[s]rsue' | awk '{print $2}'); do
  sudo kill -9 $PID
done
sleep 2
ps aux | grep srsue | grep -v grep   # should be empty
```

### uehost1 (pc808)

```bash
ssh <user>@pc808.emulab.net

for PID in $(ps aux | grep '[s]rsue' | awk '{print $2}'); do
  sudo kill -9 $PID
done
sleep 2
ps aux | grep srsue | grep -v grep   # should be empty
ss -tnlp | grep -E "201[0-9]|202[0-9]"   # all UE ZMQ ports must be free
```

### gnb2 (pc802)

```bash
ssh <user>@pc802.emulab.net

for PID in $(ps aux | grep '[s]rsenb' | awk '{print $2}'); do
  sudo kill -9 $PID
done
sleep 3
ss -tnlp | grep -E "30[0-9][0-9]"   # should be empty
```

### gnb1 (pc818)

```bash
ssh <user>@pc818.emulab.net

for PID in $(ps aux | grep '[s]rsenb' | awk '{print $2}'); do
  sudo kill -9 $PID
done
sleep 3
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
> Starting UE first = permanent ZMQ deadlock (UE stuck at "Attaching UE…" forever).

> ⚠️ **If restarting after a UE was killed:** always restart the gNB too.
> When srsue dies, the gNB's ZMQ REQ (rx) state machine does not reset.
> Reusing the old gNB instance means the new UE will never find the cell.

```bash
ssh <user>@pc818.emulab.net

mkdir -p /tmp/gnb1_logs
# Remove old log so this session is clean
rm -f /tmp/gnb1_logs/ue1_stdout.log

# Start gNB1 instance for UE1
sudo bash -c 'srsenb /etc/srsenb/enb_ue1.conf \
  >> /tmp/gnb1_logs/ue1_stdout.log 2>&1 &'

# Wait for ZMQ REP socket to bind — critical, do not skip
sleep 10

# Confirm port 2010 is listening
ss -tnlp | grep 2010
```

**Expected:** `LISTEN 0 100 0.0.0.0:2010`

```bash
# Verify gNB1 log shows "eNodeB started"
tail -5 /tmp/gnb1_logs/ue1_stdout.log
# Expected last line: "Setting frequency: DL=2680.0 Mhz, UL=2560.0 MHz for cc_idx=0 nof_prb=50"

# On core — verify MME accepted the S1 connection
grep "eNB-S1 accepted\|Number of eNBs" /var/log/open5gs/mme.log | tail -4
```

**Expected:** `eNB-S1 accepted[10.10.1.2]` · `Number of eNBs is now 1`

---

## STEP 3 — Start UE1 & Verify Attach (pc808)

```bash
ssh <user>@pc808.emulab.net

mkdir -p /tmp/ue_logs
rm -f /tmp/ue_logs/ue1_stdout.log

# Start UE1 — use sudo bash -c to keep root capabilities for netns tun creation
sudo bash -c 'srsue /etc/srsue/ue1.conf \
  >> /tmp/ue_logs/ue1_stdout.log 2>&1 &'

# Watch progress (allow ~25–35 s)
sleep 5 && tail -f /tmp/ue_logs/ue1_stdout.log
```

**Expected output sequence:**

```
Found Cell:  Mode=FDD, PCI=1, PRB=50, Ports=1, CP=Normal
Found PLMN:  Id=99970, TAC=1
Random Access Transmission: seq=..., tti=1141, ra-rnti=0x2
RRC Connected
Random Access Complete.  c-rnti=0x46, ta=0
Network attach successful. IP: 10.45.0.X
```

```bash
# Verify TUN appeared in the network namespace
sudo ip netns exec ue1 ip -br a
# Expected: tun_srsue1  UNKNOWN  10.45.0.X/24

# Ping test from UE1 namespace to core PDN gateway
sudo ip netns exec ue1 ping -c 4 10.45.0.1
```

**Expected:** 0% packet loss, RTT ~25–45 ms

> **If ping fails but IP is assigned:** the gNB was recycled from a previous session — restart
> both gNB and UE from scratch (see [Clean Restart](#clean-restart--ue-wont-connect-after-a-kill)).

---

## STEP 4 — Add UE2 through UE10 (pc818 + pc808)

Repeat the two blocks below for **N = 2, 3, 4 … 10**.
Always start the gNB instance first, wait 8 s, then the UE.

---

## Clean Restart — UE Won't Connect After a Kill

Use this whenever a UE gets killed and won't reattach (stuck at "Attaching UE…", or "Error initializing radio").

### Step A — Kill ALL UE processes on uehost1 (pc808)

```bash
ssh <user>@pc808.emulab.net

# Kill every srsue process by PID
for PID in $(ps aux | grep '[s]rsue' | awk '{print $2}'); do
  sudo kill -9 $PID
done
sleep 3

# Confirm ZMQ UE ports are free
ss -tnlp | grep -E "201[0-9]|202[0-9]" || echo "all UE ports free"
```

### Step B — Kill and restart gNB1 for the affected UE (pc818)

> Critical: you must restart the gNB, not just the UE. When srsue dies,
> the gNB ZMQ REQ socket gets stuck and a new UE will never sync.

```bash
ssh <user>@pc818.emulab.net

# Kill gNB1 instances by PID
for PID in $(ps aux | grep '[s]rsenb' | awk '{print $2}'); do
  sudo kill -9 $PID
done
sleep 3
ss -tnlp | grep -E "20[0-9][0-9]" || echo "all gNB1 ports free"

# Restart — e.g. for UE1 (port 2010)
mkdir -p /tmp/gnb1_logs
rm -f /tmp/gnb1_logs/ue1_stdout.log
sudo bash -c 'srsenb /etc/srsenb/enb_ue1.conf >> /tmp/gnb1_logs/ue1_stdout.log 2>&1 &'
sleep 10
ss -tnlp | grep 2010 && echo "✓ gNB1-UE1 ready" || echo "✗ start failed"
```

### Step C — Restart UE1 (pc808)

```bash
ssh <user>@pc808.emulab.net

rm -f /tmp/ue_logs/ue1_stdout.log
sudo bash -c 'srsue /etc/srsue/ue1.conf >> /tmp/ue_logs/ue1_stdout.log 2>&1 &'

sleep 30
grep -E "Network attach|IP:|Error init" /tmp/ue_logs/ue1_stdout.log
sudo ip netns exec ue1 ip -br a
sudo ip netns exec ue1 ping -c 4 10.45.0.1
```

---

## STEP 4 — Add UE2 through UE10 (pc818 + pc808)

Repeat the two blocks below for **N = 2, 3, 4 … 10**.
Always start the gNB instance first, wait 10 s, then the UE.
Wait for each UE to attach fully before starting the next gNB+UE pair.

### On gnb1 (pc818) — start gNB1 instance for UE-N

```bash
ssh <user>@pc818.emulab.net

N=2   # change to 3, 4, 5, 6, 7, 8, 9, 10

mkdir -p /tmp/gnb1_logs
rm -f /tmp/gnb1_logs/ue${N}_stdout.log

sudo bash -c "srsenb /etc/srsenb/enb_ue${N}.conf \
  >> /tmp/gnb1_logs/ue${N}_stdout.log 2>&1 &"

sleep 10

# Verify port bound  (formula: 20N0 — e.g. 2020 for N=2)
PORT=$((N * 10 + 2000))
ss -tnlp | grep $PORT
```

### On uehost1 (pc808) — start UE-N

```bash
ssh <user>@pc808.emulab.net

N=2   # match the gNB instance above

mkdir -p /tmp/ue_logs
rm -f /tmp/ue_logs/ue${N}_stdout.log

sudo bash -c "srsue /etc/srsue/ue${N}.conf \
  >> /tmp/ue_logs/ue${N}_stdout.log 2>&1 &"

sleep 30
grep -E "Network attach|IP:|Error init" /tmp/ue_logs/ue${N}_stdout.log

# Verify TUN in namespace
sudo ip netns exec ue${N} ip -br a
```

### Quick status check — all UE1–10

```bash
# Run on uehost1 (pc808)
for N in $(seq 1 10); do
  IP=$(sudo ip netns exec ue${N} ip -br a 2>/dev/null | grep tun_ | awk '{print $3}')
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

## STEP 8 — Start the Load-Balance Monitor

The monitor script is [`configs/loadbalance_monitor.sh`](configs/loadbalance_monitor.sh).

### How it works

```
1. Waits until all 100 base UEs (UE1–100) are attached on gNB1
2. Every poll_sec seconds:
   a. Reads dl_brate from /tmp/gnb1_ueN_metrics.csv (N=1..100) on gNB1
   b. Reads gNB1 1-min CPU load average via /proc/loadavg
3. Computes avg DL Mbps/UE and CPU utilisation %
4. THROUGHPUT trigger: avg DL < dip_thresh for dip_count consecutive polls
   CPU trigger      : CPU% > cpu_thresh for cpu_count consecutive polls
5. On trigger: migrate UE101–110 to gNB2 one at a time (each with attach+ping verify)
```

### Metrics CSV columns on gNB1

```
/tmp/gnb1_ueN_metrics.csv  (N = 1..110)
col 1 = TTI    col 2 = nof_ue    col 3 = dl_brate (Mbps)    col 4 = ul_brate (Mbps)
```

### Run the monitor

```bash
# Syntax
bash configs/loadbalance_monitor.sh [dip_thresh] [cpu_thresh] [poll_sec] [dip_count] [cpu_count]

# Defaults: DL dip < 0.5 Mbps/UE, CPU > 80%, poll 5s, 3 consecutive hits each
bash configs/loadbalance_monitor.sh

# Custom: more sensitive DL dip, lower CPU threshold
bash configs/loadbalance_monitor.sh 1.0 70 5 3 3
```

### Live monitoring output

```
┌──────────────────────────────────────────────────────────┐
│  gNB1 Monitor — 10:35:22                                 │
├──────────────────────────────────────────────────────────┤
│  Base UEs active : 100  / 100                            │
│  Total DL        : 48.2     Mbps                         │
│  Avg DL / UE     : 0.482    Mbps  (thresh < 0.5)        │
│  gNB1 CPU load   : 72.3 %  (thresh > 80%)               │
│  Dip  counter    : 2/3                                   │
│  CPU  counter    : 0/3                                   │
│  LB migrated     : 0/10 UEs moved to gNB2               │
│  Trigger         : DIP                                   │
└──────────────────────────────────────────────────────────┘
```

### Output when trigger fires

```
[10:38:11] TRIGGER: DIP — avg_dl=0.421 Mbps/UE  cpu=74.2%
[10:38:11] Migrating next LB UE to gNB2...
[10:38:11]   → Migrating UE101 (slot j=1): gNB1 → gNB2
[10:38:11]     [1/4] Starting gNB2 slot enb_ue101.conf (port 60010)
[10:38:21]     ✓ gNB2 port 60010 LISTENING
[10:38:21]     [2/4] Stopping gNB1 slot enb_ue101.conf
[10:38:23]     [3/4] Stopping UE101 srsue on uehost2 (gnb1 variant)
[10:38:25]     [4/4] Starting UE101 on uehost2 → gNB2 (ue101.conf)
[10:38:55]     ✓ UE101 migrated — IP: 10.45.0.102/24  ping: 3 received
[10:38:55] Migration 1/10 complete (UE101 on gNB2)
```

> Log is saved to `/tmp/lb_monitor_YYYYMMDD_HHMMSS.log` on the machine running the script.

### Simulate load to trigger the monitor

```bash
# On core (pc811) — start iperf3 server
ssh <user>@pc811.emulab.net
iperf3 -s -B 10.45.0.1 -p 5201 &

# On uehost1 (pc808) — drive DL traffic into several UE namespaces simultaneously
ssh <user>@pc808.emulab.net
for N in 1 2 3 4 5; do
  sudo ip netns exec ue${N} iperf3 -c 10.45.0.1 -p 5201 -t 120 -R -b 20M &
done

# Watch gNB1 avg DL metrics live
ssh <user>@pc818.emulab.net \
  "watch -n2 'tail -1 /tmp/gnb1_ue1_metrics.csv | cut -d\";\" -f1,2,3,4'"
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
| UE attaches (IP assigned) but **ping 100% loss** | Two `srsenb` sharing `10.10.1.x:2152` — only one process receives DL GTP packets | Assign unique `gtp_bind_addr` + `s1c_bind_addr` per srsenb via IP aliases (see GTP Bind Address Map) |
| UE won't reattach after being killed | gNB ZMQ REQ (rx) socket stuck on old UE address — new UE never gets IQ stream | Always kill and restart the gNB **before** restarting the UE |
| IP aliases gone after reboot | `ip addr add` is not persistent across reboots | Re-run the one-time alias setup commands (see GTP Bind Address Map section) |

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
