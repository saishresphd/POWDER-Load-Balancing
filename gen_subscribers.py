#!/usr/bin/env python3
"""
Add 20 UE subscribers to Open5GS MongoDB.
IMSI: 999700000000001 - 999700000000020 (15 digits each)
MCC=999, MNC=70
"""
import json

MONGO_DB = "open5gs"
K   = "00112233445566778899AABBCCDDEEFF"
OPC = "63BFA50EE6523365FF14C1F45F88737D"
AMF = "8000"

def make_imsi(i):
    base = "99970"          # MCC=999, MNC=70 (5 digits)
    msin = f"{i:010d}"      # 10-digit MSIN
    imsi = base + msin      # 15 digits total
    assert len(imsi) == 15, f"IMSI {imsi} is {len(imsi)} digits"
    return imsi

subscribers = []
for i in range(1, 21):
    imsi = make_imsi(i)
    sub = {
        "imsi": imsi,
        "subscribed_rau_tau_timer": 12,
        "network_access_mode": 0,
        "subscriber_status": 0,
        "access_restriction_data": 32,
        "slice": [{
            "sst": 1,
            "default_indicator": True,
            "session": [{
                "name": "internet",
                "type": 3,
                "pcc_rule": [],
                "ambr": {"uplink":   {"value": 1, "unit": 3},
                         "downlink": {"value": 1, "unit": 3}},
                "qos": {"index": 9, "arp": {
                    "priority_level": 8,
                    "pre_emption_capability": 1,
                    "pre_emption_vulnerability": 1
                }}
            }]
        }],
        "ambr": {"uplink":   {"value": 1, "unit": 3},
                 "downlink": {"value": 1, "unit": 3}},
        "security": {"k": K, "amf": AMF, "op": None, "opc": OPC},
        "schema_version": 1,
        "msisdn": []
    }
    subscribers.append(sub)

js_lines = [
    f'use {MONGO_DB}',
    'var subs = ' + json.dumps(subscribers, indent=2) + ';',
    'subs.forEach(function(s) {',
    '  var ex = db.subscribers.findOne({imsi: s.imsi});',
    '  if (!ex) { db.subscribers.insertOne(s); print("Added: " + s.imsi); }',
    '  else { print("Exists: " + s.imsi); }',
    '});',
    'print("Total subscribers: " + db.subscribers.count());'
]
js = "\n".join(js_lines)

with open("/tmp/add_subscribers.js", "w") as f:
    f.write(js)

print(f"Generated /tmp/add_subscribers.js with {len(subscribers)} subscribers")
for s in subscribers:
    print(f"  IMSI: {s['imsi']} (len={len(s['imsi'])})")
