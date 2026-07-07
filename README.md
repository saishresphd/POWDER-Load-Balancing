# POWDER Open RAN Load-Balancing Testbed

End-to-end LTE simulation on the [POWDER Wireless Testbed](https://powderwireless.net) using **Open5GS EPC**, **srsRAN 4G (ZMQ)** gNBs, and **20 simulated UEs** across 5 bare-metal d430 nodes.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Powder Profile & Node Allocation](#2-powder-profile--node-allocation)
3. [Prerequisites — Your Local Machine](#3-prerequisites--your-local-machine)
4. [Step 1 — Install Open5GS on Core (pc811)](#4-step-1--install-open5gs-on-core-pc811)
5. [Step 2 — Install srsRAN 4G on gNBs and UE Hosts](#5-step-2--install-srsran-4g-on-gnbs-and-ue-hosts)
6. [Step 3 — Configure Open5GS EPC](#6-step-3--configure-open5gs-epc)
7. [Step 4 — Add Subscribers to MongoDB](#7-step-4--add-subscribers-to-mongodb)
8. [Step 5 — Generate All Radio Configs](#8-step-5--generate-all-radio-configs)
9. [Step 6 — Start the Network](#9-step-6--start-the-network)
10. [Step 7 — Verify & Test](#10-step-7--verify--test)
11. [Troubleshooting](#11-troubleshooting)
12. [Key Parameters & Port Map](#12-key-parameters--port-map)
13. [Repository Structure](#13-repository-structure)

---

## 1. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                     POWDER Internal LAN  10.10.1.0/24               │
│                                                                      │
│  ┌──────────┐    S1AP/GTP-U    ┌──────────┐   ZMQ TCP   ┌────────┐ │
│  │  core    │◄────────────────►│  gnb1    │◄───────────►│uehost1 │ │
│  │ pc811    │    10.10.1.1     │ pc818    │  ports 2010  │ pc808  │ │
│  │10.10.1.1 │                  │10.10.1.2 │  /2011…2100  │10.10.1.4│ │
│  │          │    S1AP/GTP-U    ├──────────┤  /2101       │UE1-10  │ │
│  │Open5GS   │◄────────────────►│  gnb2    │◄───────────►├────────┤ │
│  │MME/SGW   │    10.10.1.1     │ pc802    │  ports 3010  │uehost2 │ │
│  │SMF/UPF   │                  │10.10.1.3 │  /3011…3100  │ pc801  │ │
│  │HSS       │                  └──────────┘  /3101       │10.10.1.5│ │
│  └──────────┘                                             │UE11-20 │ │
│       │ ogstun 10.45.0.1/16                               └────────┘ │
└───────┼─────────────────────────────────────────────────────────────┘
        │  UE PDN subnet: 10.45.0.0/16
        │  Each UE gets an IP like 10.45.0.x
```

### Node Role Map

| ID      | Node  | IP          | Role                          |
|---------|-------|-------------|-------------------------------|
| core    | pc811 | 10.10.1.1   | Open5GS EPC (MME+SGW+PGW+HSS) |
| gnb1    | pc818 | 10.10.1.2   | srsRAN srsenb × 10 (UE1–10)  |
| gnb2    | pc802 | 10.10.1.3   | srsRAN srsenb × 10 (UE11–20) |
| uehost1 | pc808 | 10.10.1.4   | srsRAN srsue × 10 (UE1–10)   |
| uehost2 | pc801 | 10.10.1.5   | srsRAN srsue × 10 (UE11–20)  |

### Design Decisions

- **One `srsenb` instance per UE** — srsRAN 4G ZMQ supports one UE per gNB process. Ten instances per host share the same MME/SGW.
- **ZMQ REP/REQ** — gNB TX binds a REP socket; UE RX connects with REQ. **gNB must start before UE.**
- **`netns = ueN`** in srsUE config — srsUE process runs in root namespace (ZMQ reachable), TUN interface created inside isolated `ueN` network namespace to avoid subnet conflict with `ogstun` on core.
- **`release = 8`** — srsRAN 4G release 15 overflows the EUTRA capability buffer and silently fails DRB setup.
- **`rrc_inactivity_timer = 1073741823`** — `-1` is treated as uint32 max and causes an assertion crash.

---

## 2. Powder Profile & Node Allocation

### 2.1 Create the Experiment

1. Log in to [powderwireless.net](https://powderwireless.net)
2. **Experiments → Start Experiment**
3. Select profile: `emulab-ops/UBUNTU22-64-STD` (plain Ubuntu 22.04)
4. Add **5 nodes** of type **d430**, name them: `core`, `gnb1`, `gnb2`, `uehost1`, `uehost2`
5. Add a **LAN link** connecting all 5 nodes — Powder will assign `10.10.1.x` addresses

Or use the provided `profile.py`:

```bash
# From your local machine (requires Powder CLI or use web UI)
# Upload profile.py through Experiments → Create Profile
```

### 2.2 Wait for Status = Ready

All nodes show **green/ready** in the List View. SSH commands appear in the UI:

```
ssh saish@pc811.emulab.net   # core
ssh saish@pc818.emulab.net   # gnb1
ssh saish@pc802.emulab.net   # gnb2
ssh saish@pc808.emulab.net   # uehost1
ssh saish@pc801.emulab.net   # uehost2
```

> **Note:** The remote shell on Powder nodes is **tcsh**. All scripts in this repo use `bash -s` heredoc patterns to work around this.

---

## 3. Prerequisites — Your Local Machine

```bash
# macOS / Linux
brew install openssh    # or apt install openssh-client

# Add your SSH key to Powder profile (or use password auth)
# Clone this repo
git clone https://github.com/saishresphd/POWDER-Load-Balancing.git
cd POWDER-Load-Balancing

# Generate all radio config files (requires Python 3)
python3 configs/gen_configs.py
```

Verify configs were generated:

```bash
ls configs/gnb1/   # enb_ue1.conf … enb_ue10.conf + rr/sib/rb.conf
ls configs/gnb2/   # enb_ue1.conf … enb_ue10.conf + rr/sib/rb.conf
ls configs/ues/    # ue1.conf … ue20.conf
```

---

## 4. Step 1 — Install Open5GS on Core (pc811)

SSH into the core node and run all commands there:

```bash
ssh saish@pc811.emulab.net
```

### 4.1 Install Open5GS

```bash
# Add Open5GS PPA
sudo add-apt-repository ppa:open5gs/latest -y
sudo apt update
sudo apt install -y open5gs

# Install MongoDB (needed for HSS subscriber database)
sudo apt install -y gnupg curl
curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | \
  sudo gpg -o /usr/share/keyrings/mongodb-server-7.0.gpg --dearmor
echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] \
  https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" | \
  sudo tee /etc/apt/sources.list.d/mongodb-org-7.0.list
sudo apt update
sudo apt install -y mongodb-org
sudo systemctl enable --now mongod

# Install web UI (optional, for subscriber management)
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt install -y nodejs
cd /usr/lib/open5gs && sudo npm install --save
sudo systemctl restart open5gs-webui
```

### 4.2 Configure Open5GS EPC (LTE / 4G)

The key files to edit are in `/etc/open5gs/`. We use the **4G EPC stack** (MME + SGW + SMF/PGW + UPF + HSS).

#### mme.yaml — S1AP listener on LAN IP

```bash
sudo tee /etc/open5gs/mme.yaml > /dev/null << 'EOF'
logger:
  file:
    path: /var/log/open5gs/mme.log

global:
  max:
    ue: 1024

mme:
  freeDiameter: /etc/freeDiameter/mme.conf
  s1ap:
    server:
      - address: 10.10.1.1        # LAN interface — gNBs connect here
  gtpc:
    server:
      - address: 127.0.0.2
    client:
      sgwc:
        - address: 127.0.0.3
      smf:
        - address: 127.0.0.4
  metrics:
    server:
      - address: 10.10.1.1
        port: 9090
  gummei:
    - plmn_id:
        mcc: 999
        mnc: 70
      mme_gid: 2
      mme_code: 1
  tai:
    - plmn_id:
        mcc: 999
        mnc: 70
      tac: 1
  security:
    integrity_order : [ EIA2, EIA1, EIA0 ]
    ciphering_order : [ EEA0, EEA1, EEA2 ]
  network_name:
    full: Open5GS
  mme_name: open5gs-mme0
EOF
```

#### sgwu.yaml — GTP-U listener on LAN IP

```bash
sudo sed -i 's/address: 127.0.0.6/address: 10.10.1.1/' /etc/open5gs/sgwu.yaml
```

#### upf.yaml — UPF subnet (ogstun)

```bash
# Verify ogstun subnet matches UE address pool
grep -A5 "session:" /etc/open5gs/upf.yaml
# Should show: subnet: 10.45.0.0/16
```

### 4.3 Restart All Open5GS Services

```bash
for svc in mmed sgwcd sgwud smfd upfd hssd pcrfd; do
  sudo systemctl restart open5gs-${svc}
done
sleep 3
sudo systemctl status open5gs-mmed --no-pager | head -5
```

### 4.4 Enable IP Forwarding & NAT (for UE internet access)

```bash
sudo sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf

# NAT so UE traffic can reach the internet via core eno1
sudo iptables -t nat -A POSTROUTING -s 10.45.0.0/16 ! -o ogstun -j MASQUERADE
sudo iptables -A FORWARD -i ogstun -j ACCEPT
```

---

## 5. Step 2 — Install srsRAN 4G on gNBs and UE Hosts

Run this on **all 4 nodes**: gnb1 (pc818), gnb2 (pc802), uehost1 (pc808), uehost2 (pc801).

```bash
# SSH into each node and run:
ssh saish@pc818.emulab.net   # repeat for pc802, pc808, pc801
```

### 5.1 Install Build Dependencies

```bash
sudo apt update
sudo apt install -y \
  cmake make gcc g++ pkg-config libfftw3-dev libmbedtls-dev \
  libsctp-dev libconfig++-dev libboost-program-options-dev \
  libzmq3-dev libuhd-dev uhd-host \
  python3 git
```

### 5.2 Clone and Build srsRAN 4G v23.4 with ZMQ

```bash
cd /tmp
git clone https://github.com/srsran/srsRAN_4G.git srsran4g
cd srsran4g
git checkout eea87b1          # pinned to v23.4.0

mkdir build && cd build
cmake .. \
  -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_WERROR=OFF \
  -DENABLE_ZMQ=ON \
  -DENABLE_UHD=OFF
make -j$(nproc)
sudo make install
sudo ldconfig
```

### 5.3 Verify Installation

```bash
srsenb --version   # should print: Version 23.4.0
srsue  --version
ldconfig -p | grep libsrsran_rf_zmq   # should list the .so
```

### 5.4 Install Default Config Files

```bash
sudo srsran_install_configs.sh service
ls /etc/srsenb/    # enb.conf  sib.conf  rr.conf  rb.conf
ls /etc/srsue/     # ue.conf
```

---

## 6. Step 3 — Configure Open5GS EPC

> These configs are already applied if you ran Section 4. This section documents what was changed from the Open5GS defaults.

### What Changed from Defaults

| File | Change | Reason |
|------|--------|--------|
| `mme.yaml` | `s1ap.server.address: 10.10.1.1` | gNBs connect over LAN, not localhost |
| `mme.yaml` | `mcc: 999, mnc: 70, tac: 1` | Must match gNB + UE PLMN |
| `sgwu.yaml` | `gtpu.server.address: 10.10.1.1` | GTP-U from gNBs arrives on LAN |
| `upf.yaml` | `session.subnet: 10.45.0.0/16` | UE PDN address pool |
| `amf.yaml` | **Disabled** (commented out) | AMF is 5G; we use MME for 4G/LTE |

---

## 7. Step 4 — Add Subscribers to MongoDB

Run on **core (pc811)**:

```bash
ssh saish@pc811.emulab.net
```

### 7.1 Add 20 Subscribers via mongosh

```bash
mongosh open5gs << 'MONGOEOF'
// Remove any stale test subscribers
db.subscribers.deleteMany({imsi: {$regex: /^99970012/}});

// Add UE1-20
for (var i = 1; i <= 20; i++) {
  var imsi = "99970000000" + String(i).padStart(4, "0");
  db.subscribers.insertOne({
    schema_version: 1,
    imsi: imsi,
    msisdn: [],
    imeisv: [],
    security: {
      k:   "00112233445566778899aabbccddeeff",
      amf: "8000",
      op:  null,
      opc: "63bfa50ee6523365ff14c1f45f88737d"
    },
    ambr: { downlink: { value: 1, unit: 3 }, uplink: { value: 1, unit: 3 } },
    slice: [{
      sst: 1, sd: "000001",
      default_indicator: true,
      session: [{
        name: "internet",
        type: 3,
        qos: { index: 9, arp: { priority_level: 8, pre_emption_capability: 1, pre_emption_vulnerability: 1 } },
        ambr: { downlink: { value: 1, unit: 3 }, uplink: { value: 1, unit: 3 } },
        ue: { addr: "0.0.0.0" },
        pcc_rule: []
      }]
    }],
    access_restriction_data: 32,
    subscriber_status: 0,
    network_access_mode: 0,
    subscribed_rau_tau_timer: 12
  });
}
print("Inserted. Total subscribers: " + db.subscribers.countDocuments());
MONGOEOF
```

### 7.2 Verify

```bash
mongosh --quiet open5gs --eval \
  'db.subscribers.find({},{imsi:1,_id:0}).forEach(d=>print(d.imsi))'
# Should list 999700000000001 through 999700000000020
```

---

## 8. Step 5 — Generate All Radio Configs

Run from your **local machine** in the repo root:

```bash
python3 configs/gen_configs.py
```

This creates:

```
configs/
├── gnb1/
│   ├── enb_ue1.conf  … enb_ue10.conf   # one srsenb per UE
│   ├── rr.conf
│   ├── sib.conf
│   └── rb.conf
├── gnb2/
│   ├── enb_ue1.conf  … enb_ue10.conf   # serves UE11-20
│   ├── rr.conf
│   ├── sib.conf
│   └── rb.conf
└── ues/
    ├── ue1.conf  … ue10.conf   # connect to gnb1
    └── ue11.conf … ue20.conf   # connect to gnb2
```

### ZMQ Port Assignment

Each UE gets a **dedicated port pair** so gNBs and UEs don't conflict:

| UE | gNB Host | gNB TX (REP) | UE TX (REP) |
|----|----------|--------------|-------------|
| UE1 | gnb1 | `tcp://*:2010` | `tcp://*:2011` |
| UE2 | gnb1 | `tcp://*:2020` | `tcp://*:2021` |
| … | gnb1 | … | … |
| UE10 | gnb1 | `tcp://*:2100` | `tcp://*:2101` |
| UE11 | gnb2 | `tcp://*:3010` | `tcp://*:3011` |
| … | gnb2 | … | … |
| UE20 | gnb2 | `tcp://*:3100` | `tcp://*:3101` |

---

## 9. Step 6 — Start the Network

### Option A — Automated (recommended)

From your local machine:

```bash
# Full 20-UE startup (deploys configs + starts gNBs + UEs)
bash configs/start_network.sh

# Stop everything
bash configs/stop_network.sh

# Check attachment status
bash configs/check_status.sh
```

### Option B — Single UE test first

```bash
bash configs/test_one_ue.sh
```

This tests just UE1 ↔ gNB1 ↔ core and includes a ping validation. **Run this before scaling to 20 UEs.**

### Option C — Manual step-by-step

#### Step 6.1 — Kill any stale processes (all 4 radio nodes)

```bash
for h in pc818 pc802 pc808 pc801; do
  ssh saish@${h}.emulab.net 'bash -s' << 'EOF' &
sudo pkill -9 srsenb 2>/dev/null || true
sudo pkill -9 srsue  2>/dev/null || true
sleep 3
EOF
done
wait
```

#### Step 6.2 — Deploy configs

```bash
# gNB1
for f in configs/gnb1/*.conf; do scp "$f" saish@pc818.emulab.net:/tmp/; done
ssh saish@pc818.emulab.net 'bash -s' << 'EOF'
sudo cp /tmp/enb_ue*.conf /tmp/rr.conf /tmp/sib.conf /tmp/rb.conf /etc/srsenb/
sudo ldconfig
EOF

# gNB2
for f in configs/gnb2/*.conf; do scp "$f" saish@pc802.emulab.net:/tmp/; done
ssh saish@pc802.emulab.net 'bash -s' << 'EOF'
sudo cp /tmp/enb_ue*.conf /tmp/rr.conf /tmp/sib.conf /tmp/rb.conf /etc/srsenb/
sudo ldconfig
EOF

# uehost1 (UE1-10)
for i in $(seq 1 10); do scp configs/ues/ue${i}.conf saish@pc808.emulab.net:/tmp/; done
ssh saish@pc808.emulab.net 'bash -s' << 'EOF'
for i in $(seq 1 10); do
  sudo cp /tmp/ue${i}.conf /etc/srsue/ue${i}.conf
  ip netns list | grep -q "^ue${i}" || sudo ip netns add ue${i}
  sudo ip netns exec ue${i} ip link del tun_srsue${i} 2>/dev/null || true
done
sudo ldconfig
EOF

# uehost2 (UE11-20)
for i in $(seq 11 20); do scp configs/ues/ue${i}.conf saish@pc801.emulab.net:/tmp/; done
ssh saish@pc801.emulab.net 'bash -s' << 'EOF'
for i in $(seq 11 20); do
  sudo cp /tmp/ue${i}.conf /etc/srsue/ue${i}.conf
  ip netns list | grep -q "^ue${i}" || sudo ip netns add ue${i}
  sudo ip netns exec ue${i} ip link del tun_srsue${i} 2>/dev/null || true
done
sudo ldconfig
EOF
```

#### Step 6.3 — Start gNBs (MUST be before UEs)

```bash
# gNB1 — 10 instances for UE1-10
ssh saish@pc818.emulab.net 'bash -s' << 'EOF'
mkdir -p /tmp/gnb1_logs
for i in $(seq 1 10); do
  sudo srsenb /etc/srsenb/enb_ue${i}.conf \
    --log.filename=/tmp/gnb1_logs/ue${i}.log \
    > /tmp/gnb1_logs/ue${i}_stdout.log 2>&1 &
  sleep 0.5
done
EOF

# gNB2 — 10 instances for UE11-20
ssh saish@pc802.emulab.net 'bash -s' << 'EOF'
mkdir -p /tmp/gnb2_logs
for i in $(seq 1 10); do
  sudo srsenb /etc/srsenb/enb_ue${i}.conf \
    --log.filename=/tmp/gnb2_logs/ue${i}.log \
    > /tmp/gnb2_logs/ue${i}_stdout.log 2>&1 &
  sleep 0.5
done
EOF

# Wait for all gNBs to register with MME
sleep 15
ssh saish@pc811.emulab.net 'sudo tail -3 /var/log/open5gs/mme.log'
# Expect: [Added] Number of eNBs is now 20
```

#### Step 6.4 — Start UEs (staggered, after gNBs ready)

```bash
# uehost1 — UE1-10 (2s stagger to avoid ZMQ race)
ssh saish@pc808.emulab.net 'bash -s' << 'EOF'
mkdir -p /tmp/ue_logs
for i in $(seq 1 10); do
  sudo ip netns exec ue${i} ip link del tun_srsue${i} 2>/dev/null || true
  sudo srsue /etc/srsue/ue${i}.conf \
    --log.filename=/tmp/ue_logs/ue${i}.log \
    > /tmp/ue_logs/ue${i}_stdout.log 2>&1 &
  sleep 2
done
EOF

# uehost2 — UE11-20
ssh saish@pc801.emulab.net 'bash -s' << 'EOF'
mkdir -p /tmp/ue_logs
for i in $(seq 11 20); do
  sudo ip netns exec ue${i} ip link del tun_srsue${i} 2>/dev/null || true
  sudo srsue /etc/srsue/ue${i}.conf \
    --log.filename=/tmp/ue_logs/ue${i}.log \
    > /tmp/ue_logs/ue${i}_stdout.log 2>&1 &
  sleep 2
done
EOF

echo "Waiting 60s for all UEs to attach..."
sleep 60
```

---

## 10. Step 7 — Verify & Test

### 10.1 Check Attachment Status

```bash
bash configs/check_status.sh
```

Expected output:
```
uehost1 total attached: 10/10
uehost2 total attached: 10/10
Attach Complete events: 20
```

### 10.2 Check UE IP Address

```bash
# On uehost1 — each UE's tun is in its own netns
ssh saish@pc808.emulab.net 'bash -s' << 'EOF'
for i in $(seq 1 10); do
  ip=$(sudo ip netns exec ue${i} ip -br a show tun_srsue${i} 2>/dev/null | awk '{print $3}')
  echo "UE${i}: $ip"
done
EOF
```

### 10.3 Ping Test (Data Plane)

```bash
# Ping core UPF gateway (10.45.0.1) from UE1
ssh saish@pc808.emulab.net \
  'sudo ip netns exec ue1 ping -c 5 10.45.0.1'

# Ping from all 10 UEs on uehost1
ssh saish@pc808.emulab.net 'bash -s' << 'EOF'
for i in $(seq 1 10); do
  result=$(sudo ip netns exec ue${i} ping -c 3 -W 2 10.45.0.1 2>&1 | grep -E "received|loss")
  echo "UE${i}: $result"
done
EOF
```

### 10.4 iperf3 Throughput Test

```bash
# Start iperf3 server on core
ssh saish@pc811.emulab.net 'iperf3 -s -D'

# Run TCP test from UE1
ssh saish@pc808.emulab.net \
  'sudo ip netns exec ue1 iperf3 -c 10.45.0.1 -t 10 -i 1'

# Run UDP test from UE1
ssh saish@pc808.emulab.net \
  'sudo ip netns exec ue1 iperf3 -c 10.45.0.1 -u -b 5M -t 10'
```

### 10.5 Monitor MME Attach Events

```bash
ssh saish@pc811.emulab.net \
  'sudo tail -f /var/log/open5gs/mme.log | grep -E "Attach complete|Number of"'
```

---

## 11. Troubleshooting

### UE stuck at "Attaching UE…" (3-line log, no cell found)

**Cause:** ZMQ deadlock — gNB TX REP is waiting for UE REQ but the gNB was started after the UE, or a previous session left stale state.

**Fix:**
```bash
# Always: kill gNB first, then UE, then restart gNB first
ssh saish@pc818.emulab.net 'sudo pkill -9 srsenb'
ssh saish@pc808.emulab.net 'bash -s' << 'EOF'
sudo pkill -9 srsue
sleep 3
ss -tnlp | grep 2011   # must be empty before restarting
EOF
# Then start gNB, wait 8s, then start UE
```

### gNB crashes immediately with "Invalid timer duration=4294967295"

**Cause:** `rrc_inactivity_timer = -1` is treated as uint32 = 4294967295.

**Fix:** Use `rrc_inactivity_timer = 1073741823` (max allowed value ≈ 12 days).

### UE attaches but ping drops — "Service request ignored"

**Cause:** `release = 15` causes `Error packing EUTRA capabilities` → DRB never set up → UE NAS/RRC state desync.

**Fix:** Set `release = 8` in `[rrc]` section of all UE configs.

### Port 2011 already in use

```bash
# Find and kill the process holding the port
ssh saish@pc808.emulab.net 'bash -s' << 'EOF'
sudo lsof -i :2011
sudo pkill -9 srsue
sleep 3
ss -tnlp | grep 2011   # should be empty
EOF
```

### gNB2 S1AP connection flapping (connect → refused → connect)

**Cause:** Previous srsenb instances still running and holding ports.

**Fix:**
```bash
ssh saish@pc802.emulab.net 'bash -s' << 'EOF'
sudo pkill -9 srsenb
sleep 5
ss -tnlp | grep -E "30[0-9][0-9]0"   # all gNB2 TX ports must be free
EOF
```

### UE tun not in ue1 netns (in root namespace instead)

**Cause:** `netns = ue1` missing from `[gw]` section.

**Fix:** Ensure `[gw]` section contains `netns = ueN`. The srsUE process stays in root ns; only the TUN interface is moved into the netns.

### MME: "No Context in TEID"

**Cause:** gNB sent an InitialUEMessage then crashed (usually the `-1` timer bug).

**Fix:** Fix `rrc_inactivity_timer`, restart MME to clear stale state, restart gNB.

```bash
ssh saish@pc811.emulab.net 'sudo systemctl restart open5gs-mmed'
sleep 3
```

---

## 12. Key Parameters & Port Map

### PLMN / Radio Parameters

| Parameter | Value |
|-----------|-------|
| MCC | 999 |
| MNC | 70 |
| TAC | 1 |
| dl_earfcn | 3350 (Band 7, DL 2680 MHz) |
| n_prb | 50 (10 MHz bandwidth) |
| base_srate | 11.52e6 |
| UE release | 8 |

### Subscriber Credentials

| Field | Value |
|-------|-------|
| K | `00112233445566778899aabbccddeeff` |
| OPC | `63bfa50ee6523365ff14c1f45f88737d` |
| Algorithm | Milenage |
| APN | `internet` |
| IMSI range | `999700000000001` – `999700000000020` |

### ZMQ Port Map

| UE | gNB | gNB TX REP | UE TX REP | gNB RX REQ target |
|----|-----|-----------|-----------|-------------------|
| UE1 | gnb1 | 10.10.1.2:2010 | 10.10.1.4:2011 | tcp://10.10.1.4:2011 |
| UE2 | gnb1 | 10.10.1.2:2020 | 10.10.1.4:2021 | tcp://10.10.1.4:2021 |
| UE10 | gnb1 | 10.10.1.2:2100 | 10.10.1.4:2101 | tcp://10.10.1.4:2101 |
| UE11 | gnb2 | 10.10.1.3:3010 | 10.10.1.5:3011 | tcp://10.10.1.5:3011 |
| UE20 | gnb2 | 10.10.1.3:3100 | 10.10.1.5:3101 | tcp://10.10.1.5:3101 |

### Address Summary

| Component | Address |
|-----------|---------|
| MME S1AP | 10.10.1.1:36412 (SCTP) |
| SGW-U GTP-U | 10.10.1.1:2152 (UDP) |
| ogstun (UPF gateway) | 10.45.0.1/16 |
| UE PDN pool | 10.45.0.2 – 10.45.255.254 |

---

## 13. Repository Structure

```
POWDER-Load-Balancing/
├── README.md                    # This file
├── profile.py                   # Powder experiment profile (5-node d430)
├── configs/
│   ├── gen_configs.py           # Generate all 40 radio config files
│   ├── start_network.sh         # Deploy + start full 20-UE network
│   ├── stop_network.sh          # Kill all srsenb/srsue processes
│   ├── check_status.sh          # Check attach status of all 20 UEs
│   ├── test_one_ue.sh           # Single UE smoke test (UE1 only)
│   ├── gnb1/                    # gNB1 configs (serves UE1-10)
│   │   ├── enb_ue1.conf … enb_ue10.conf
│   │   ├── rr.conf
│   │   ├── sib.conf
│   │   └── rb.conf
│   ├── gnb2/                    # gNB2 configs (serves UE11-20)
│   │   ├── enb_ue1.conf … enb_ue10.conf
│   │   ├── rr.conf
│   │   ├── sib.conf
│   │   └── rb.conf
│   └── ues/                     # UE configs
│       ├── ue1.conf  … ue10.conf    # connect to gnb1
│       └── ue11.conf … ue20.conf   # connect to gnb2
└── install/
    ├── install_srsran4g.sh      # Build srsRAN 4G from source with ZMQ
    └── setup_core.sh            # Configure Open5GS + add subscribers
```

---

## Quick Reference

```bash
# ── From local machine ─────────────────────────────────────────────

# Generate configs
python3 configs/gen_configs.py

# Single UE smoke test
bash configs/test_one_ue.sh

# Full 20-UE startup
bash configs/start_network.sh

# Stop everything
bash configs/stop_network.sh

# Check status
bash configs/check_status.sh

# ── Core node (pc811) ──────────────────────────────────────────────

# Watch MME attach events
ssh saish@pc811.emulab.net \
  'sudo tail -f /var/log/open5gs/mme.log | grep -E "Attach|eNBs"'

# ── uehost1 (pc808) ────────────────────────────────────────────────

# Ping from UE1
ssh saish@pc808.emulab.net \
  'sudo ip netns exec ue1 ping -c 5 10.45.0.1'

# Check all 10 UE IPs
ssh saish@pc808.emulab.net 'bash -s' << 'EOF'
for i in $(seq 1 10); do
  ip=$(sudo ip netns exec ue${i} ip -br a show tun_srsue${i} 2>/dev/null | awk '{print $3}')
  echo "UE${i}: ${ip:-not attached}"
done
EOF
```
