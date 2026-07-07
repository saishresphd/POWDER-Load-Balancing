#!/bin/bash
# setup_core.sh — Configure Open5GS EPC and add 20 subscribers
# Run on: core (pc811)
# Usage: bash setup_core.sh
set -e

echo "=== Installing Open5GS ==="
sudo add-apt-repository ppa:open5gs/latest -y
sudo apt update
sudo apt install -y open5gs

echo "=== Installing MongoDB ==="
sudo apt install -y gnupg curl
curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | \
  sudo gpg -o /usr/share/keyrings/mongodb-server-7.0.gpg --dearmor
echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] \
  https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" | \
  sudo tee /etc/apt/sources.list.d/mongodb-org-7.0.list
sudo apt update
sudo apt install -y mongodb-org
sudo systemctl enable --now mongod

echo "=== Configuring MME ==="
sudo tee /etc/open5gs/mme.yaml > /dev/null << 'YAML'
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
      - address: 10.10.1.1
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
YAML

echo "=== Configuring SGW-U GTP-U on LAN IP ==="
sudo python3 - << 'PYEOF'
import re, pathlib
p = pathlib.Path("/etc/open5gs/sgwu.yaml")
t = p.read_text()
t = re.sub(r'(gtpu:\s+server:\s+- address:)\s+127\.0\.0\.6', r'\1 10.10.1.1', t)
p.write_text(t)
print("sgwu.yaml updated")
PYEOF

echo "=== Enabling IP forwarding ==="
sudo sysctl -w net.ipv4.ip_forward=1
grep -q "ip_forward=1" /etc/sysctl.conf || \
  echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf

echo "=== Adding iptables NAT for UE subnet ==="
sudo iptables -t nat -C POSTROUTING -s 10.45.0.0/16 ! -o ogstun -j MASQUERADE 2>/dev/null || \
  sudo iptables -t nat -A POSTROUTING -s 10.45.0.0/16 ! -o ogstun -j MASQUERADE
sudo iptables -C FORWARD -i ogstun -j ACCEPT 2>/dev/null || \
  sudo iptables -A FORWARD -i ogstun -j ACCEPT

echo "=== Restarting Open5GS services ==="
for svc in mmed sgwcd sgwud smfd upfd hssd pcrfd; do
  sudo systemctl restart open5gs-${svc} 2>/dev/null || true
done
sleep 3

echo "=== Adding 20 subscribers to MongoDB ==="
mongosh --quiet open5gs << 'MONGOEOF'
db.subscribers.deleteMany({imsi: {$regex: /^99970012/}});
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
      ambr: { downlink: { value: 1, unit: 3 }, uplink: { value: 1, unit: 3 } },
      slice: [{
        sst: 1, sd: "000001",
        default_indicator: true,
        session: [{
          name: "internet",
          type: 3,
          qos: { index: 9, arp: { priority_level: 8,
            pre_emption_capability: 1, pre_emption_vulnerability: 1 } },
          ambr: { downlink: { value: 1, unit: 3 }, uplink: { value: 1, unit: 3 } },
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

echo ""
echo "=== Verify ==="
sudo systemctl is-active open5gs-mmed open5gs-sgwcd open5gs-sgwud \
  open5gs-smfd open5gs-upfd open5gs-hssd
echo ""
echo "✓ Core setup complete on $(hostname -s)"
echo "  MME listening on 10.10.1.1:36412 (SCTP)"
echo "  Subscribers: $(mongosh --quiet open5gs --eval 'db.subscribers.countDocuments()')"
