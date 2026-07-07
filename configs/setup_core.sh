#!/bin/bash
# ==========================================================================
#  setup_core.sh  — Configure Open5GS AMF + UPF + SMF for multi-UE scenario
#  Run on: core (pc811, 10.10.1.1)
#  - AMF: PLMN=999/70, TAC=1, NGAP on 10.10.1.1
#  - UPF: GTP-U on 10.10.1.1
#  - SMF: points to UPF at 10.10.1.1
#  - Adds 20 subscribers via mongosh
# ==========================================================================
set -euo pipefail

echo "[core] Configuring Open5GS for load-balancing scenario..."

# ── AMF config ────────────────────────────────────────────────────────────
sudo tee /etc/open5gs/amf.yaml > /dev/null << 'AMF'
logger:
  file:
    path: /var/log/open5gs/amf.log
global:
  max:
    ue: 1024
amf:
  sbi:
    server:
      - address: 10.10.1.1
        port: 7777
    client:
      scp:
        - uri: http://127.0.0.200:7777
  ngap:
    server:
      - address: 10.10.1.1
  metrics:
    server:
      - address: 10.10.1.1
        port: 9090
  guami:
    - plmn_id:
        mcc: 999
        mnc: 70
      amf_id:
        region: 2
        set: 1
  tai:
    - plmn_id:
        mcc: 999
        mnc: 70
      tac: 1
  plmn_support:
    - plmn_id:
        mcc: 999
        mnc: 70
      s_nssai:
        - sst: 1
  security:
    integrity_order : [ NIA2, NIA1, NIA0 ]
    ciphering_order : [ NEA0, NEA1, NEA2 ]
  network_name:
    full: Open5GS
    short: O5GS
  amf_name: open5gs-amf0
  time:
    t3512:
      value: 540
AMF

# ── UPF config ────────────────────────────────────────────────────────────
sudo tee /etc/open5gs/upf.yaml > /dev/null << 'UPF'
logger:
  file:
    path: /var/log/open5gs/upf.log
global:
  max:
    ue: 1024
upf:
  pfcp:
    server:
      - address: 10.10.1.1
    client:
  gtpu:
    server:
      - address: 10.10.1.1
  session:
    - subnet: 10.45.0.0/16
      gateway: 10.45.0.1
    - subnet: 2001:db8:cafe::/48
      gateway: 2001:db8:cafe::1
  metrics:
    server:
      - address: 10.10.1.1
        port: 9091
UPF

# ── SMF config (point UPF to real IP) ─────────────────────────────────────
sudo sed -i 's/address: 127.0.0.7/address: 10.10.1.1/g' /etc/open5gs/smf.yaml
sudo sed -i 's/address: 127.0.0.4/address: 10.10.1.1/g' /etc/open5gs/smf.yaml

# ── Enable IP forwarding + NAT for UE internet access ─────────────────────
sudo sysctl -w net.ipv4.ip_forward=1
sudo iptables -t nat -A POSTROUTING -s 10.45.0.0/16 -j MASQUERADE 2>/dev/null || true
sudo iptables -t nat -A POSTROUTING -s 2001:db8:cafe::/48 -j MASQUERADE 2>/dev/null || true

# ── Restart all Open5GS services ──────────────────────────────────────────
echo "[core] Restarting Open5GS services..."
for svc in nrfd scpd amfd smfd upfd ausfd udmd udrd pcfd nssfd; do
    sudo systemctl restart open5gs-${svc} 2>/dev/null || true
done
sleep 3
echo "[core] Service status:"
systemctl list-units --type=service | grep open5gs | grep -v "●"

# ── Add 20 subscribers ────────────────────────────────────────────────────
echo "[core] Adding 20 UE subscribers to MongoDB..."
python3 /tmp/gen_subscribers.py
mongosh open5gs /tmp/add_subscribers.js 2>/dev/null || \
    mongo open5gs /tmp/add_subscribers.js 2>/dev/null || \
    echo "WARN: mongosh failed, check manually"

echo "[core] Setup complete!"
