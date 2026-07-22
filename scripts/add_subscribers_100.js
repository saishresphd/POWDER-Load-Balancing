// add_subscribers_100.js
// Run: mongosh open5gs scripts/add_subscribers_100.js
// Adds UE21-100 and UE101-110 subscribers to Open5GS (skips existing IMSIs)
//
// IMSI format: 99970 + zero-padded 10-digit index
// K   = 00112233445566778899aabbccddeeff
// OPC = 63bfa50ee6523365ff14c1f45f88737d

const db = db.getSiblingDB("open5gs");

function makeImsi(i) {
  return "99970" + String(i).padStart(10, "0");
}

const K   = "00112233445566778899aabbccddeeff";
const OPC = "63bfa50ee6523365ff14c1f45f88737d";
const APN = "internet";

function makeSubscriber(i) {
  const imsi = makeImsi(i);
  return {
    imsi: imsi,
    subscribed_rau_tau_timer: 12,
    network_access_mode: 2,
    subscriber_status: 0,
    access_restriction_data: 32,
    slice: [{
      sst: 1,
      default_indicator: true,
      session: [{
        name: APN,
        type: 3,
        pcc_rule: [],
        ambr: { uplink: { value: 1, unit: 3 }, downlink: { value: 1, unit: 3 } },
        qos: { index: 9, arp: { priority_level: 8, pre_emption_capability: 1, pre_emption_vulnerability: 1 } }
      }]
    }],
    ambr: { uplink: { value: 1, unit: 3 }, downlink: { value: 1, unit: 3 } },
    security: {
      k: K,
      op: null,
      opc: OPC,
      amf: "8000",
      sqn: NumberLong(0)
    },
    schema_version: 1,
    __v: 0
  };
}

let added = 0;
let skipped = 0;

// UE21-100 (base load UEs not yet in DB)
for (let i = 21; i <= 100; i++) {
  const imsi = makeImsi(i);
  const exists = db.subscribers.findOne({ imsi: imsi });
  if (!exists) {
    db.subscribers.insertOne(makeSubscriber(i));
    added++;
  } else {
    skipped++;
  }
}

// UE101-110 (LB UEs)
for (let i = 101; i <= 110; i++) {
  const imsi = makeImsi(i);
  const exists = db.subscribers.findOne({ imsi: imsi });
  if (!exists) {
    db.subscribers.insertOne(makeSubscriber(i));
    added++;
  } else {
    skipped++;
  }
}

print("Added: " + added + "  Skipped (already exist): " + skipped);
print("Total subscribers now: " + db.subscribers.countDocuments());
