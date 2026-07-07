# POWDER Open RAN Load-Balancing Testbed

End-to-end LTE simulation on the [POWDER Wireless Testbed](https://powderwireless.net) using **Open5GS EPC**, **srsRAN 4G (ZMQ)** base stations, and **20 simulated UEs** across 5 bare-metal `d430` nodes — no RF hardware required.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Powder Profile — Node Allocation](#2-powder-profile--node-allocation)
3. [Step 1 — Install Open5GS on Core](#3-step-1--install-open5gs-on-core-pc811)
4. [Step 2 — Install srsRAN 4G on Radio Nodes](#4-step-2--install-srsran-4g-on-radio-nodes)
5. [Step 3 — Configure Open5GS EPC](#5-step-3--configure-open5gs-epc)
6. [Step 4 — Add Subscribers (MongoDB)](#6-step-4--add-subscribers-mongodb)
7. [Step 5 — Generate Radio Configs](#7-step-5--generate-radio-configs)
8. [Step 6 — Network Namespaces (UE Hosts)](#8-step-6--network-namespaces-ue-hosts)
9. [Step 7 — Start the Network](#9-step-7--start-the-network)
10. [Step 8 — Verify & Ping Test](#10-step-8--verify--ping-test)
11. [Viewing Logs](#11-viewing-logs)
12. [Stopping the Network](#12-stopping-the-network)
13. [Troubleshooting](#13-troubleshooting)
14. [Key Parameters Reference](#14-key-parameters-reference)
15. [Repository Structure](#15-repository-structure)

---

## 1. Architecture Overview

```
┌──────────────────────────── POWDER LAN  10.10.1.0/24 ────────────────────────────┐
│                                                                                    │
│  ┌──────────────┐   S1AP (SCTP)    ┌──────────────┐   ZMQ TCP    ┌────────────┐  │
│  │   core       │ ◄──────────────► │   gnb1       │ ◄──────────► │  uehost1   │  │
│  │   pc811      │   10.10.1.1      │   pc818      │  ports 2010  │  pc808     │  │
│  │  10.10.1.1   │                  │  10.10.1.2   │  –2101       │  10.10.1.4 │  │
│  │              │   GTP-U (UDP)    ├──────────────┤              │  UE1–10    │  │
│  │  Open5GS     │ ◄──────────────► │   gnb2       │ ◄──────────► ├────────────┤  │
│  │  MME  SGW    │   10.10.1.1      │   pc802      │  ports 3010  │  uehost2   │  │
│  │  SMF  UPF    │                  │  10.10.1.3   │  –3101       │  pc801     │  │
│  │  HSS         │                  └──────────────┘              │  10.10.1.5 │  │
│  └──────┬───────┘                                                │  UE11–20   │  │
│         │ ogstun                                                  └────────────┘  │
│         │ 10.45.0.1/16  ← UE PDN gateway                                         │
└─────────┴──────────────────────────────────────────────────────────────────────────┘
```

### Node Roles

| Powder ID | FQDN | LAN IP | Role |
|-----------|------|--------|------|
| core | pc811.emulab.net | 10.10.1.1 | Open5GS EPC — MME, SGW, SMF/PGW, UPF, HSS |
| gnb1 | pc818.emulab.net | 10.10.1.2 | srsRAN srsenb × 10 instances (UE1–10) |
| gnb2 | pc802.emulab.net | 10.10.1.3 | srsRAN srsenb × 10 instances (UE11–20) |
| uehost1 | pc808.emulab.net | 10.10.1.4 | srsRAN srsue × 10 (UE1–10, netns ue1–ue10) |
| uehost2 | pc801.emulab.net | 10.10.1.5 | srsRAN srsue × 10 (UE11–20, netns ue11–ue20) |

### Key Design Choices

| Choice | Reason |
|--------|--------|
| **One `srsenb` per UE** | srsRAN 4G ZMQ supports exactly one UE per gNB process |
| **`release = 8`** | Release 15 overflows the EUTRA capability ASN.1 buffer — DRB never set up |
| **`rrc_inactivity_timer = 1073741823`** | Value `-1` is cast to uint32 max → assertion crash on first RACH |
| **gNB starts before UE** | ZMQ REP socket must bind before REQ connects — reverse order deadlocks |
| **`netns = ueN` in `[gw]`** | srsUE process stays in root ns (ZMQ reachable from gNB); only the TUN moves into the isolated namespace to avoid conflict with `ogstun` on core |

---

## 2. Powder Profile — Node Allocation

### 2.1 Create the Experiment

1. Log in at [powderwireless.net](https://powderwireless.net)
2. Click **Experiments → Start Experiment**
3. Choose profile **`emulab-ops/UBUNTU22-64-STD`**
4. Request **5 × d430 nodes**, name them: `core`, `gnb1`, `gnb2`, `uehost1`, `uehost2`
5. Add a **LAN** connecting all 5 — Powder assigns `10.10.1.x` automatically
6. Submit and wait until all nodes show **Status: ready** (green)

### 2.2 SSH Access

Powder shows the exact SSH command in the **List View**. The pattern is:

```bash
ssh <your_username>@pc811.emulab.net   # core
ssh <your_username>@pc818.emulab.net   # gnb1
ssh <your_username>@pc802.emulab.net   # gnb2
ssh <your_username>@pc808.emulab.net   # uehost1
ssh <your_username>@pc801.emulab.net   # uehost2
```

> **Shell note:** Powder nodes default to **tcsh**. Every multi-line block below uses `bash -s` to avoid tcsh syntax conflicts.

---

## 3. Step 1 — Install Open5GS on Core (pc811)

```bash
ssh <user>@pc811.emulab.net
```

### 3.1 Add Open5GS PPA and install

```bash
sudo add-apt-repository ppa:open5gs/latest -y
sudo apt update
sudo apt install -y open5gs
```

### 3.2 Install MongoDB (subscriber database)

```bash
# Import MongoDB 7.0 GPG key
sudo apt install -y gnupg curl
curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc \
  | sudo gpg -o /usr/share/keyrings/mongodb-server-7.0.gpg --dearmor

# Add repository
echo "deb [ arch=amd64,arm64 \
  signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] \
  https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" \
  | sudo tee /etc/apt/sources.list.d/mongodb-org-7.0.list

sudo apt update
sudo apt install -y mongodb-org
sudo systemctl enable --now mongod

# Verify
mongosh --eval 'db.runCommand({ping:1})'
# Expected: { ok: 1 }
```

### 3.3 Enable IP forwarding and NAT

```bash
# Enable forwarding (survives reboot via sysctl.conf)
sudo sysctl -w net.ipv4.ip_forward=1
grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf \
  || echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf

# NAT: UE traffic (10.45.0.0/16) out via core's WAN interface
sudo iptables -t nat -A POSTROUTING -s 10.45.0.0/16 ! -o ogstun -j MASQUERADE
sudo iptables -A FORWARD -i ogstun -j ACCEPT

# Make iptables rules persistent
sudo apt install -y iptables-persistent
sudo netfilter-persistent save
```

---

## 4. Step 2 — Install srsRAN 4G on Radio Nodes

Run the following on **each** of the 4 radio nodes: gnb1, gnb2, uehost1, uehost2.

```bash
# Open 4 terminals (or use tmux):
ssh <user>@pc818.emulab.net   # gnb1
ssh <user>@pc802.emulab.net   # gnb2
ssh <user>@pc808.emulab.net   # uehost1
ssh <user>@pc801.emulab.net   # uehost2
```

### 4.1 Install build dependencies

```bash
sudo apt update
sudo apt install -y \
  cmake make gcc g++ pkg-config \
  libfftw3-dev libmbedtls-dev libsctp-dev \
  libconfig++-dev libboost-program-options-dev \
  libzmq3-dev \
  python3 git
```

### 4.2 Clone srsRAN 4G and build with ZMQ

```bash
cd /tmp
git clone https://github.com/srsran/srsRAN_4G.git srsran4g
cd srsran4g

# Pin to the tested commit (v23.4.0)
git checkout eea87b1

mkdir build && cd build

cmake .. \
  -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_WERROR=OFF \
  -DENABLE_ZMQ=ON \
  -DENABLE_UHD=OFF

# Build (takes ~10 min on d430)
make -j$(nproc)

# Install to /usr/local/bin and /usr/local/lib
sudo make install
sudo ldconfig
```

### 4.3 Install default config files

```bash
sudo srsran_install_configs.sh service
# Creates /etc/srsenb/{enb,sib,rr,rb}.conf and /etc/srsue/ue.conf
```

### 4.4 Verify

```bash
srsenb --version
# Expected: Version 23.4.0

srsue --version
# Expected: Version 23.4.0

ldconfig -p | grep libsrsran_rf_zmq
# Expected: libsrsran_rf_zmq.so.0 => /usr/local/lib/libsrsran_rf_zmq.so.0
```

---

## 5. Step 3 — Configure Open5GS EPC

All commands on **core (pc811)**.

### 5.1 Configure MME — S1AP on LAN IP

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
      - address: 10.10.1.1        # LAN IP — gNBs connect here via S1AP
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

### 5.2 Configure SGW-U — GTP-U on LAN IP

```bash
# Change SGW-U GTP-U bind from 127.0.0.6 to the LAN IP
# so gNBs can send GTP-U packets to it
sudo python3 << 'PYEOF'
import re, pathlib
p = pathlib.Path("/etc/open5gs/sgwu.yaml")
txt = p.read_text()
txt = re.sub(
    r'(sgwu:.*?gtpu:.*?server:.*?- address:)\s*127\.0\.0\.6',
    r'\1 10.10.1.1',
    txt, flags=re.DOTALL
)
p.write_text(txt)
print("sgwu.yaml updated — GTP-U now on 10.10.1.1")
PYEOF
```

### 5.3 Verify UPF subnet

```bash
grep -A5 "session:" /etc/open5gs/upf.yaml
# Must show:  subnet: 10.45.0.0/16
# ogstun interface carries this — UEs get IPs from this pool
```

### 5.4 Restart all EPC services

```bash
for svc in mmed sgwcd sgwud smfd upfd hssd pcrfd; do
  sudo systemctl restart open5gs-${svc}
  echo "${svc}: $(sudo systemctl is-active open5gs-${svc})"
done
```

Expected output — all `active`:
```
mmed: active
sgwcd: active
sgwud: active
smfd: active
upfd: active
hssd: active
pcrfd: active
```

### 5.5 Verify MME is listening on S1AP port

```bash
sudo ss -tnlp | grep 36412
# Expected: LISTEN  0  ...  10.10.1.1:36412
```

---

## 6. Step 4 — Add Subscribers (MongoDB)

On **core (pc811)**.

### 6.1 Add 20 UE subscribers

```bash
mongosh open5gs << 'MONGOEOF'
// Clean up any stale test entries first
db.subscribers.deleteMany({ imsi: { $regex: /^99970012/ } });

// Insert UE1 through UE20
for (var i = 1; i <= 20; i++) {
  var imsi = "99970000000" + String(i).padStart(4, "0");
  db.subscribers.replaceOne(
    { imsi: imsi },
    {
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
      ambr: {
        downlink: { value: 1, unit: 3 },
        uplink:   { value: 1, unit: 3 }
      },
      slice: [{
        sst: 1,
        sd: "000001",
        default_indicator: true,
        session: [{
          name: "internet",
          type: 3,
          qos: {
            index: 9,
            arp: {
              priority_level: 8,
              pre_emption_capability: 1,
              pre_emption_vulnerability: 1
            }
          },
          ambr: {
            downlink: { value: 1, unit: 3 },
            uplink:   { value: 1, unit: 3 }
          },
          ue: { addr: "0.0.0.0" },
          pcc_rule: []
        }]
      }],
      access_restriction_data: 32,
      subscriber_status: 0,
      network_access_mode: 0,
      subscribed_rau_tau_timer: 12
    },
    { upsert: true }
  );
}
print("Done. Total subscribers: " + db.subscribers.countDocuments());
MONGOEOF
```

### 6.2 Verify subscribers

```bash
mongosh --quiet open5gs \
  --eval 'db.subscribers.find({},{imsi:1,_id:0}).forEach(d=>print(d.imsi))'
```

Expected (20 lines):
```
999700000000001
999700000000002
...
999700000000020
```

---

## 7. Step 5 — Generate Radio Configs

On your **local machine** (or any node with Python 3):

```bash
# Clone the repo
git clone https://github.com/<your_github_user>/POWDER-Load-Balancing.git
cd POWDER-Load-Balancing

# Generate all 40 config files
python3 configs/gen_configs.py
```

This creates:

```
configs/
├── gnb1/
│   ├── enb_ue1.conf   ← srsenb for UE1  (ZMQ tx=2010, rx=2011)
│   ├── enb_ue2.conf   ← srsenb for UE2  (ZMQ tx=2020, rx=2021)
│   ├── ...
│   ├── enb_ue10.conf  ← srsenb for UE10 (ZMQ tx=2100, rx=2101)
│   ├── rr.conf
│   ├── sib.conf
│   └── rb.conf
├── gnb2/
│   ├── enb_ue1.conf   ← srsenb for UE11 (ZMQ tx=3010, rx=3011)
│   ├── ...
│   └── enb_ue10.conf  ← srsenb for UE20 (ZMQ tx=3100, rx=3101)
└── ues/
    ├── ue1.conf   – ue10.conf    ← connect to gnb1
    └── ue11.conf  – ue20.conf   ← connect to gnb2
```

### ZMQ port scheme

| UE | gNB | gNB TX REP binds | UE TX REP binds | Flow |
|----|-----|-----------------|-----------------|------|
| UE1 | gnb1 | `*:2010` | `*:2011` | gNB→UE DL on 2010, UE→gNB UL on 2011 |
| UE2 | gnb1 | `*:2020` | `*:2021` | |
| UE10 | gnb1 | `*:2100` | `*:2101` | |
| UE11 | gnb2 | `*:3010` | `*:3011` | gNB→UE DL on 3010, UE→gNB UL on 3011 |
| UE20 | gnb2 | `*:3100` | `*:3101` | |

---

## 8. Step 6 — Network Namespaces (UE Hosts)

Each UE gets an isolated network namespace so its `tun` interface does not conflict with the `10.45.0.0/16` subnet already present on core's `ogstun`.

### On uehost1 (pc808) — create ue1–ue10

```bash
ssh <user>@pc808.emulab.net

for i in $(seq 1 10); do
  sudo ip netns add ue${i} 2>/dev/null || true
  echo "netns ue${i} ready"
done

# Verify
ip netns list
# ue10  ue9  ue8 ... ue1
```

### On uehost2 (pc801) — create ue11–ue20

```bash
ssh <user>@pc801.emulab.net

for i in $(seq 11 20); do
  sudo ip netns add ue${i} 2>/dev/null || true
  echo "netns ue${i} ready"
done

ip netns list
# ue20 ue19 ... ue11
```

---

## 9. Step 7 — Start the Network

> **Critical ordering rule:** gNBs must always start **before** UEs.
> ZMQ uses REP/REQ — the gNB TX REP socket must be bound before the UE RX REQ connects.
> Reversing the order causes a permanent deadlock.

### Option A — Automated (recommended)

From your local machine inside the repo:

```bash
# Single UE smoke test (UE1 only — validates full stack before scaling)
bash configs/test_one_ue.sh

# Full 20-UE network
bash configs/start_network.sh

# Stop everything cleanly
bash configs/stop_network.sh

# Check attachment status
bash configs/check_status.sh
```

### Option B — Manual, node by node

#### 9.1 Deploy configs from local machine

```bash
# ── gNB1 ──────────────────────────────────────────────────────
for f in configs/gnb1/*.conf; do
  scp "$f" <user>@pc818.emulab.net:/tmp/
done
ssh <user>@pc818.emulab.net 'bash -s' << 'EOF'
sudo cp /tmp/enb_ue*.conf /etc/srsenb/
sudo cp /tmp/rr.conf /tmp/sib.conf /tmp/rb.conf /etc/srsenb/
sudo ldconfig
echo "gNB1 configs deployed"
EOF

# ── gNB2 ──────────────────────────────────────────────────────
for f in configs/gnb2/*.conf; do
  scp "$f" <user>@pc802.emulab.net:/tmp/
done
ssh <user>@pc802.emulab.net 'bash -s' << 'EOF'
sudo cp /tmp/enb_ue*.conf /etc/srsenb/
sudo cp /tmp/rr.conf /tmp/sib.conf /tmp/rb.conf /etc/srsenb/
sudo ldconfig
echo "gNB2 configs deployed"
EOF

# ── uehost1 (UE1-10) ──────────────────────────────────────────
for i in $(seq 1 10); do
  scp configs/ues/ue${i}.conf <user>@pc808.emulab.net:/tmp/
done
ssh <user>@pc808.emulab.net 'bash -s' << 'EOF'
for i in $(seq 1 10); do
  sudo cp /tmp/ue${i}.conf /etc/srsue/ue${i}.conf
  sudo ip netns add ue${i} 2>/dev/null || true
  sudo ip netns exec ue${i} ip link del tun_srsue${i} 2>/dev/null || true
done
sudo ldconfig
echo "uehost1 configs deployed"
EOF

# ── uehost2 (UE11-20) ─────────────────────────────────────────
for i in $(seq 11 20); do
  scp configs/ues/ue${i}.conf <user>@pc801.emulab.net:/tmp/
done
ssh <user>@pc801.emulab.net 'bash -s' << 'EOF'
for i in $(seq 11 20); do
  sudo cp /tmp/ue${i}.conf /etc/srsue/ue${i}.conf
  sudo ip netns add ue${i} 2>/dev/null || true
  sudo ip netns exec ue${i} ip link del tun_srsue${i} 2>/dev/null || true
done
sudo ldconfig
echo "uehost2 configs deployed"
EOF
```

#### 9.2 Start gNB1 — 10 instances (UE1–10)

```bash
ssh <user>@pc818.emulab.net 'bash -s' << 'EOF'
mkdir -p /tmp/gnb1_logs
for i in $(seq 1 10); do
  sudo srsenb /etc/srsenb/enb_ue${i}.conf \
    --log.filename=/tmp/gnb1_logs/ue${i}.log \
    > /tmp/gnb1_logs/ue${i}_stdout.log 2>&1 &
  echo "  gNB1/UE${i} started PID=$!"
  sleep 0.5      # slight stagger so SCTP ports don't race
done
echo "gNB1: all 10 instances started"
EOF
```

#### 9.3 Start gNB2 — 10 instances (UE11–20)

```bash
ssh <user>@pc802.emulab.net 'bash -s' << 'EOF'
mkdir -p /tmp/gnb2_logs
for i in $(seq 1 10); do
  sudo srsenb /etc/srsenb/enb_ue${i}.conf \
    --log.filename=/tmp/gnb2_logs/ue${i}.log \
    > /tmp/gnb2_logs/ue${i}_stdout.log 2>&1 &
  echo "  gNB2/UE${i+10} started PID=$!"
  sleep 0.5
done
echo "gNB2: all 10 instances started"
EOF
```

#### 9.4 Wait for gNBs to register with MME

```bash
# Watch MME log — wait for "Number of eNBs is now 20"
ssh <user>@pc811.emulab.net 'sudo tail -f /var/log/open5gs/mme.log' &
sleep 15
# You should see 20 lines: "eNB-S1 accepted[10.10.1.2]" and "[10.10.1.3]"
kill %1
```

#### 9.5 Start UE1–10 on uehost1 (staggered 2s each)

```bash
ssh <user>@pc808.emulab.net 'bash -s' << 'EOF'
mkdir -p /tmp/ue_logs
for i in $(seq 1 10); do
  # Clear any stale tun from previous run
  sudo ip netns exec ue${i} ip link del tun_srsue${i} 2>/dev/null || true
  sudo srsue /etc/srsue/ue${i}.conf \
    --log.filename=/tmp/ue_logs/ue${i}.log \
    > /tmp/ue_logs/ue${i}_stdout.log 2>&1 &
  echo "  UE${i} started PID=$!"
  sleep 2    # 2s gap prevents ZMQ port bind race
done
echo "uehost1: all 10 UEs started"
EOF
```

#### 9.6 Start UE11–20 on uehost2 (staggered 2s each)

```bash
ssh <user>@pc801.emulab.net 'bash -s' << 'EOF'
mkdir -p /tmp/ue_logs
for i in $(seq 11 20); do
  sudo ip netns exec ue${i} ip link del tun_srsue${i} 2>/dev/null || true
  sudo srsue /etc/srsue/ue${i}.conf \
    --log.filename=/tmp/ue_logs/ue${i}.log \
    > /tmp/ue_logs/ue${i}_stdout.log 2>&1 &
  echo "  UE${i} started PID=$!"
  sleep 2
done
echo "uehost2: all 10 UEs started"
EOF
```

#### 9.7 Wait for all UEs to attach

```bash
# Allow up to 60s for all 20 UEs to complete attach
sleep 60
```

---

## 10. Step 8 — Verify & Ping Test

### 10.1 Check MME attach events (core)

```bash
ssh <user>@pc811.emulab.net \
  'sudo grep -E "Attach complete|Number of MME-UEs" /var/log/open5gs/mme.log | tail -25'
```

Expected — 20 attach complete lines:
```
07/07 13:47:06.627: [emm] INFO: [999700000000001] Attach complete
07/07 13:47:09.276: [emm] INFO: [999700000000002] Attach complete
...
07/07 13:47:13.062: [emm] INFO: [999700000000020] Attach complete
```

### 10.2 Check UE IP addresses (uehost1)

```bash
ssh <user>@pc808.emulab.net 'bash -s' << 'EOF'
echo "UE1-10 tunnel addresses:"
for i in $(seq 1 10); do
  ip=$(sudo ip netns exec ue${i} ip -br a show tun_srsue${i} 2>/dev/null \
       | awk '{print $3}')
  printf "  UE%-3s  tun_srsue%-3s  %s\n" "$i" "$i" "${ip:-NOT ATTACHED}"
done
EOF
```

Expected:
```
UE1   tun_srsue1    10.45.0.4/24
UE2   tun_srsue2    10.45.0.5/24
...
UE10  tun_srsue10   10.45.0.13/24
```

### 10.3 Check UE IP addresses (uehost2)

```bash
ssh <user>@pc801.emulab.net 'bash -s' << 'EOF'
for i in $(seq 11 20); do
  ip=$(sudo ip netns exec ue${i} ip -br a show tun_srsue${i} 2>/dev/null \
       | awk '{print $3}')
  printf "  UE%-3s  tun_srsue%-3s  %s\n" "$i" "$i" "${ip:-NOT ATTACHED}"
done
EOF
```

### 10.4 Ping test — UE1 to core UPF gateway

```bash
ssh <user>@pc808.emulab.net \
  'sudo ip netns exec ue1 ping -c 5 10.45.0.1'
```

Expected:
```
64 bytes from 10.45.0.1: icmp_seq=1 ttl=64 time=35.2 ms
64 bytes from 10.45.0.1: icmp_seq=2 ttl=64 time=38.7 ms
64 bytes from 10.45.0.1: icmp_seq=3 ttl=64 time=41.1 ms
5 packets transmitted, 5 received, 0% packet loss
```

### 10.5 Ping all 10 UEs on uehost1

```bash
ssh <user>@pc808.emulab.net 'bash -s' << 'EOF'
for i in $(seq 1 10); do
  loss=$(sudo ip netns exec ue${i} ping -c 3 -W 2 10.45.0.1 2>&1 \
         | grep -oE "[0-9]+% packet loss")
  printf "  UE%-3s  %s\n" "$i" "${loss:-NOT ATTACHED}"
done
EOF
```

### 10.6 iperf3 throughput test

```bash
# Start server on core
ssh <user>@pc811.emulab.net 'iperf3 -s -D'

# TCP throughput from UE1
ssh <user>@pc808.emulab.net \
  'sudo ip netns exec ue1 iperf3 -c 10.45.0.1 -t 10 -i 2'

# UDP throughput from UE1 at 5 Mbps
ssh <user>@pc808.emulab.net \
  'sudo ip netns exec ue1 iperf3 -c 10.45.0.1 -u -b 5M -t 10'

# Stop server
ssh <user>@pc811.emulab.net 'pkill iperf3'
```

---

## 11. Viewing Logs

### Core — Open5GS service logs

```bash
ssh <user>@pc811.emulab.net

# MME — S1AP signalling, attach/detach events
sudo tail -f /var/log/open5gs/mme.log

# SGW-C — session control
sudo tail -f /var/log/open5gs/sgwc.log

# SGW-U — GTP-U data plane
sudo tail -f /var/log/open5gs/sgwu.log

# UPF — packet forwarding
sudo tail -f /var/log/open5gs/upf.log

# HSS — authentication
sudo tail -f /var/log/open5gs/hss.log

# SMF — session management
sudo tail -f /var/log/open5gs/smf.log

# Watch all attach events live
sudo tail -f /var/log/open5gs/mme.log \
  | grep --line-buffered -E "Attach|eNBs|UEs|IMSI"
```

### gNB1 — per-UE instance logs

```bash
ssh <user>@pc818.emulab.net

# Live stdout for UE1's gNB instance
tail -f /tmp/gnb1_logs/ue1_stdout.log

# Detailed log for UE1's gNB instance
tail -f /tmp/gnb1_logs/ue1.log

# Watch RRC/S1AP events across all 10 instances
grep -h "S1AP\|RRC\|RACH\|TEID\|tunnel" /tmp/gnb1_logs/*.log | tail -30

# Count currently running gNB instances
pgrep -c srsenb
```

### gNB2 — per-UE instance logs

```bash
ssh <user>@pc802.emulab.net

tail -f /tmp/gnb2_logs/ue1_stdout.log    # UE11's gNB
tail -f /tmp/gnb2_logs/ue1.log

grep -h "S1AP\|RRC\|RACH" /tmp/gnb2_logs/*.log | tail -30
```

### uehost1 — UE logs

```bash
ssh <user>@pc808.emulab.net

# Live log for UE1 (key events: cell found, attach, DRB)
tail -f /tmp/ue_logs/ue1.log

# stdout (shows startup, ZMQ init)
tail -f /tmp/ue_logs/ue1_stdout.log

# Filter key attach events
grep -E "Found cell|Attach Accept|Attach complete|GW IP|DRB|error" \
  /tmp/ue_logs/ue1.log | tail -20

# Check attach status of all 10 UEs at once
for i in $(seq 1 10); do
  status=$(grep -c "Attach complete" /tmp/ue_logs/ue${i}.log 2>/dev/null \
           && echo "ATTACHED" || echo "not attached")
  echo "UE${i}: ${status}"
done
```

### uehost2 — UE logs

```bash
ssh <user>@pc801.emulab.net

tail -f /tmp/ue_logs/ue11.log
grep -E "Found cell|Attach|GW|DRB|error" /tmp/ue_logs/ue11.log | tail -20
```

### Check ZMQ connections (any radio node)

```bash
# On gnb1 — verify both ZMQ sockets are ESTAB for UE1
ssh <user>@pc818.emulab.net 'ss -tnp | grep -E "2010|2011"'
# Expected: two ESTAB lines per UE

# On uehost1 — verify UE1 ZMQ connections
ssh <user>@pc808.emulab.net 'ss -tnp | grep -E "2010|2011"'
```

---

## 12. Stopping the Network

### Automated

```bash
bash configs/stop_network.sh
```

### Manual

```bash
# Kill all srsenb instances on both gNBs
for h in pc818 pc802; do
  ssh <user>@${h}.emulab.net 'bash -s' << 'EOF' &
sudo pkill -9 srsenb 2>/dev/null || true
sleep 2
echo "$(hostname -s): srsenb stopped"
EOF
done
wait

# Kill all srsue instances on both UE hosts
for h in pc808 pc801; do
  ssh <user>@${h}.emulab.net 'bash -s' << 'EOF' &
sudo pkill -9 srsue 2>/dev/null || true
sleep 2
echo "$(hostname -s): srsue stopped"
EOF
done
wait

# Clean stale tun interfaces in namespaces
ssh <user>@pc808.emulab.net 'bash -s' << 'EOF'
for i in $(seq 1 10); do
  sudo ip netns exec ue${i} ip link del tun_srsue${i} 2>/dev/null || true
done
EOF

ssh <user>@pc801.emulab.net 'bash -s' << 'EOF'
for i in $(seq 11 20); do
  sudo ip netns exec ue${i} ip link del tun_srsue${i} 2>/dev/null || true
done
EOF

echo "Network stopped."
```

---

## 13. Troubleshooting

### ❌ UE stuck at "Attaching UE…" — only 3 log lines, no cell found

**Symptom:** `/tmp/ue_logs/ue1.log` contains:
```
Added LTE radio bearer with LCID 0 in Transparent Mode
Read Home PLMN Id=99970
Switching on
```
Then nothing for minutes.

**Cause:** ZMQ deadlock. The gNB TX REP socket is blocking waiting for a REQ from UE, but it was started after the UE (or holds stale state from a previous session).

**Fix — always restart gNB first, then UE:**
```bash
# 1. Kill gNB for this UE slot
ssh <user>@pc818.emulab.net 'sudo pkill -9 srsenb 2>/dev/null; true'

# 2. Kill UE and wait for port to free
ssh <user>@pc808.emulab.net 'bash -s' << 'EOF'
sudo pkill -9 srsue 2>/dev/null || true
sleep 3
# Confirm port 2011 is free before restarting
ss -tnlp | grep 2011 && echo "STILL BUSY — wait longer" || echo "Port free"
EOF

# 3. Restart gNB first
ssh <user>@pc818.emulab.net \
  'sudo srsenb /etc/srsenb/enb_ue1.conf --log.filename=stdout \
   > /tmp/gnb1_ue1_stdout.log 2>&1 & echo "gNB PID=$!"'

# 4. Wait 8 seconds for gNB to bind port and register with MME
sleep 8
ssh <user>@pc811.emulab.net 'sudo tail -2 /var/log/open5gs/mme.log'
# Expect: [Added] Number of eNBs is now X

# 5. Then start UE
ssh <user>@pc808.emulab.net \
  'sudo srsue /etc/srsue/ue1.conf --log.filename=stdout \
   > /tmp/ue1_stdout.log 2>&1 & echo "UE PID=$!"'
```

---

### ❌ gNB crashes immediately — "Invalid timer duration=4294967295"

**Symptom in `/tmp/gnb1_logs/ue1_stdout.log`:**
```
Assertion Failure: Invalid timer duration=4294967295>1073741823
```

**Cause:** `rrc_inactivity_timer = -1` in `[expert]` section. The value `-1` is cast to `uint32_t` = `0xFFFFFFFF` = `4294967295`, which exceeds the allowed maximum.

**Fix:**
```bash
# On gnb1 — patch the config
sudo sed -i 's/rrc_inactivity_timer = -1/rrc_inactivity_timer = 1073741823/' \
  /etc/srsenb/enb_ue1.conf

# Verify
grep rrc_inactivity /etc/srsenb/enb_ue1.conf
# Expected: rrc_inactivity_timer = 1073741823
```

All configs in this repo already use `1073741823`.

---

### ❌ UE attaches but ping drops — "Service request ignored"

**Symptom in `/tmp/ue_logs/ue1.log`:**
```
[NAS] Service request ignored. State = REGISTERED, with substate NORMAL-SERVICE
[STCK] Can't deliver SDU for EPS bearer 5. Dropping it.
```

**Cause:** `release = 15` in `[rrc]` section causes `Error packing EUTRA capabilities`. The RRC Reconfiguration (which sets up the DRB) fails silently — no Data Radio Bearer is established, so data cannot flow.

**Fix:**
```bash
sudo sed -i 's/release.*=.*15/release = 8/' /etc/srsue/ue1.conf
grep "release" /etc/srsue/ue1.conf
# Expected: release     = 8
```

All UE configs in this repo use `release = 8`.

---

### ❌ Port already in use — "Address already in use"

**Symptom in gNB stdout:**
```
Error: binding transmitter socket (tcp://*:2010): Address already in use
Error initializing radio.
```

**Cause:** A previous `srsenb` process is still running and holding the ZMQ port.

**Fix:**
```bash
# Find the process holding port 2010
ssh <user>@pc818.emulab.net 'bash -s' << 'EOF'
sudo lsof -i :2010
sudo pkill -9 srsenb 2>/dev/null || true
sleep 3
ss -tnlp | grep 2010 && echo "STILL BUSY" || echo "Port 2010 free"
EOF
```

---

### ❌ gNB2 S1AP flapping — connect then "connection refused" immediately

**Symptom in MME log:**
```
eNB-S1 accepted[10.10.1.3]:44662
[Added] Number of eNBs is now 21
eNB-S1[10.10.1.3] connection refused!!!
[Removed] Number of eNBs is now 20
```

**Cause:** Old `srsenb` instances from a previous session are still running on pc802, causing port conflicts that crash the new instances immediately.

**Fix:**
```bash
ssh <user>@pc802.emulab.net 'bash -s' << 'EOF'
sudo pkill -9 srsenb 2>/dev/null || true
sleep 5
# All gNB2 ZMQ TX ports must be free
ss -tnlp | grep -E "3[0-9][0-9]0"
# Should return nothing
EOF
```

---

### ❌ UE tun interface in wrong namespace

**Symptom:**
```bash
sudo ip netns exec ue1 ip -br a
# lo   DOWN
# (no tun_srsue1)
```

But `ip addr show tun_srsue1` in the root namespace shows it.

**Cause:** `netns = ue1` is missing from the `[gw]` section in the UE config.

**Fix:**
```bash
grep -A5 '^\[gw\]' /etc/srsue/ue1.conf
# Must show:  netns = ue1
# If missing:
sudo sed -i '/^\[gw\]/a netns = ue1' /etc/srsue/ue1.conf
```

---

### ❌ MME: "No Context in TEID" error

**Symptom in MME log:**
```
[mme] ERROR: No Context in TEID [ACTION:2]
[emm] ERROR: emm_state_authentication: Expectation failed
```

**Cause:** gNB crashed mid-attach (usually the `-1` timer bug), leaving stale S1 state in MME.

**Fix:**
```bash
# Restart MME to clear stale state, then restart the gNB
ssh <user>@pc811.emulab.net 'sudo systemctl restart open5gs-mmed'
sleep 3
# Then restart the gNB instance and UE
```

---

### ❌ Log file is 0 bytes / permission denied

**Cause:** A previous run as `root` created `/tmp/ue1.log` owned by root, and the new process (also root but different uid) can't overwrite it.

**Fix — use `--log.filename=stdout` to bypass file logging:**
```bash
sudo srsue /etc/srsue/ue1.conf \
  --log.filename=stdout \
  > /tmp/ue1_stdout.log 2>&1 &
```

Or force-remove the stale file:
```bash
sudo rm -f /tmp/ue1.log /tmp/ue1_stdout.log
```

---

### Quick diagnostic checklist

```bash
# 1. Are all Open5GS services running on core?
ssh <user>@pc811.emulab.net \
  'systemctl is-active open5gs-mmed open5gs-sgwcd open5gs-sgwud \
   open5gs-smfd open5gs-upfd open5gs-hssd'
# All must be: active

# 2. Is MME listening on S1AP?
ssh <user>@pc811.emulab.net 'sudo ss -tnlp | grep 36412'
# Expected: LISTEN 0 ... 10.10.1.1:36412

# 3. Are gNB ZMQ ports bound?
ssh <user>@pc818.emulab.net 'ss -tnlp | grep -E "20[0-9][0-9]0"'
# Should show LISTEN for each active gNB instance

# 4. Are ZMQ connections ESTAB between gNB and UE?
ssh <user>@pc808.emulab.net 'ss -tnp | grep -E "2010|2011"'
# Should show two ESTAB lines per attached UE

# 5. Are UE tun interfaces up in their netns?
ssh <user>@pc808.emulab.net \
  'for i in 1 2 3; do
     sudo ip netns exec ue${i} ip -br a show tun_srsue${i} 2>/dev/null \
     || echo "UE${i}: no tun"
   done'
```

---

## 14. Key Parameters Reference

### PLMN / Radio

| Parameter | Value | Notes |
|-----------|-------|-------|
| MCC | 999 | Test PLMN |
| MNC | 70 | Test PLMN |
| TAC | 1 | Must match in mme.yaml, enb conf, and rr.conf |
| dl_earfcn | 3350 | LTE Band 7, DL 2680 MHz |
| n_prb | 50 | 10 MHz bandwidth |
| base_srate | 11.52e6 | Matches 50 PRB; use 23.04e6 for 100 PRB |
| UE release | **8** | Release 15 breaks EUTRA capabilities ASN.1 |
| rrc_inactivity_timer | **1073741823** | `-1` causes uint32 assertion crash |

### Subscriber Credentials (all 20 UEs share same K/OPC)

| Field | Value |
|-------|-------|
| K | `00112233445566778899aabbccddeeff` |
| OPC | `63bfa50ee6523365ff14c1f45f88737d` |
| AMF | `8000` |
| Algorithm | Milenage |
| APN | `internet` |
| IMSI | `999700000000001` – `999700000000020` |

### Network Addresses

| Component | Address | Protocol |
|-----------|---------|----------|
| MME S1AP | 10.10.1.1:36412 | SCTP |
| MME GTP-C | 127.0.0.2:2123 | UDP |
| SGW-C GTP-C | 127.0.0.3:2123 | UDP |
| SGW-U GTP-U | 10.10.1.1:2152 | UDP |
| SMF GTP-C | 127.0.0.4:2123 | UDP |
| UPF PFCP | 127.0.0.7:8805 | UDP |
| ogstun (PDN GW) | 10.45.0.1/16 | — |
| UE PDN pool | 10.45.0.2 – 10.45.255.254 | — |

### ZMQ Port Map (complete)

| UE | gNB | gNB TX REP | UE TX REP |
|----|-----|-----------|-----------|
| UE1 | gnb1 | 10.10.1.2:2010 | 10.10.1.4:2011 |
| UE2 | gnb1 | 10.10.1.2:2020 | 10.10.1.4:2021 |
| UE3 | gnb1 | 10.10.1.2:2030 | 10.10.1.4:2031 |
| UE4 | gnb1 | 10.10.1.2:2040 | 10.10.1.4:2041 |
| UE5 | gnb1 | 10.10.1.2:2050 | 10.10.1.4:2051 |
| UE6 | gnb1 | 10.10.1.2:2060 | 10.10.1.4:2061 |
| UE7 | gnb1 | 10.10.1.2:2070 | 10.10.1.4:2071 |
| UE8 | gnb1 | 10.10.1.2:2080 | 10.10.1.4:2081 |
| UE9 | gnb1 | 10.10.1.2:2090 | 10.10.1.4:2091 |
| UE10 | gnb1 | 10.10.1.2:2100 | 10.10.1.4:2101 |
| UE11 | gnb2 | 10.10.1.3:3010 | 10.10.1.5:3011 |
| UE12 | gnb2 | 10.10.1.3:3020 | 10.10.1.5:3021 |
| UE13 | gnb2 | 10.10.1.3:3030 | 10.10.1.5:3031 |
| UE14 | gnb2 | 10.10.1.3:3040 | 10.10.1.5:3041 |
| UE15 | gnb2 | 10.10.1.3:3050 | 10.10.1.5:3051 |
| UE16 | gnb2 | 10.10.1.3:3060 | 10.10.1.5:3061 |
| UE17 | gnb2 | 10.10.1.3:3070 | 10.10.1.5:3071 |
| UE18 | gnb2 | 10.10.1.3:3080 | 10.10.1.5:3081 |
| UE19 | gnb2 | 10.10.1.3:3090 | 10.10.1.5:3091 |
| UE20 | gnb2 | 10.10.1.3:3100 | 10.10.1.5:3101 |

---

## 15. Repository Structure

```
POWDER-Load-Balancing/
├── README.md                        ← This file
│
├── install/
│   ├── setup_core.sh                ← Open5GS install + mme.yaml + 20 subscribers
│   └── install_srsran4g.sh          ← srsRAN 4G v23.4 build from source with ZMQ
│
└── configs/
    ├── gen_configs.py               ← Generates all 40 srsenb + srsue configs
    │
    ├── start_network.sh             ← Automated: deploy + gNBs + UEs (all 20)
    ├── stop_network.sh              ← Kill all srsenb/srsue, clean tun interfaces
    ├── check_status.sh              ← Check attachment status of all 20 UEs
    ├── test_one_ue.sh               ← Single UE smoke test (UE1 + ping)
    │
    ├── gnb1/                        ← gNB1 configs (serves UE1–10)
    │   ├── enb_ue1.conf             ← enb_id=0x001, ZMQ tx=2010 rx←2011
    │   ├── enb_ue2.conf             ← enb_id=0x002, ZMQ tx=2020 rx←2021
    │   ├── ...
    │   ├── enb_ue10.conf            ← enb_id=0x00A, ZMQ tx=2100 rx←2101
    │   ├── rr.conf                  ← Radio resource config (TAC=1, PCI=1)
    │   ├── sib.conf                 ← System information blocks
    │   └── rb.conf                  ← Radio bearer config
    │
    ├── gnb2/                        ← gNB2 configs (serves UE11–20)
    │   ├── enb_ue1.conf             ← enb_id=0x011, ZMQ tx=3010 rx←3011
    │   ├── ...
    │   └── enb_ue10.conf            ← enb_id=0x01A, ZMQ tx=3100 rx←3101
    │
    └── ues/
        ├── ue1.conf                 ← IMSI=999700000000001, netns=ue1
        ├── ue2.conf
        ├── ...
        ├── ue10.conf                ← IMSI=999700000000010, netns=ue10
        ├── ue11.conf                ← IMSI=999700000000011, netns=ue11
        ├── ...
        └── ue20.conf                ← IMSI=999700000000020, netns=ue20
```

---

## Quick Reference Card

```bash
# ═══════════════════════════════════════════════════════
#  FROM LOCAL MACHINE
# ═══════════════════════════════════════════════════════

# Generate all radio configs
python3 configs/gen_configs.py

# Single UE smoke test (run this first!)
bash configs/test_one_ue.sh

# Start full 20-UE network
bash configs/start_network.sh

# Stop everything
bash configs/stop_network.sh

# Check all 20 UE attachment status
bash configs/check_status.sh


# ═══════════════════════════════════════════════════════
#  ON CORE (pc811)
# ═══════════════════════════════════════════════════════

# Watch MME attach events live
sudo tail -f /var/log/open5gs/mme.log | grep -E "Attach|eNBs|UEs"

# Count attached UEs
sudo grep -c "Attach complete" /var/log/open5gs/mme.log

# Restart MME (clears stale state after gNB crash)
sudo systemctl restart open5gs-mmed


# ═══════════════════════════════════════════════════════
#  ON GNB1 (pc818)
# ═══════════════════════════════════════════════════════

# How many srsenb instances running?
pgrep -c srsenb

# Watch UE1's gNB log live
tail -f /tmp/gnb1_logs/ue1_stdout.log

# Kill all gNB instances
sudo pkill -9 srsenb


# ═══════════════════════════════════════════════════════
#  ON UEHOST1 (pc808)
# ═══════════════════════════════════════════════════════

# Check UE1 IP (inside its netns)
sudo ip netns exec ue1 ip -br a show tun_srsue1

# Ping from UE1
sudo ip netns exec ue1 ping -c 5 10.45.0.1

# Watch UE1 attach log live
tail -f /tmp/ue_logs/ue1.log

# Check all 10 UE IPs at once
for i in $(seq 1 10); do
  ip=$(sudo ip netns exec ue${i} ip -br a show tun_srsue${i} 2>/dev/null | awk '{print $3}')
  echo "UE${i}: ${ip:-not attached}"
done

# Kill all UE processes
sudo pkill -9 srsue
```
