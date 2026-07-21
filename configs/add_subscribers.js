// add_subscribers.js
// =============================================================================
// Load 110 subscribers into the Open5GS MongoDB on core (pc811).
//
// IMSI formula : 99970{i:010d}   (15 digits)
//   UE1   = 999700000000001
//   UE100 = 999700000000100
//   UE110 = 999700000000110
//
// K   = 00112233445566778899aabbccddeeff
// OPc = 63bfa50ee6523365ff14c1f45f88737d
// APN = internet (IPv4)
//
// Usage (run on core pc811):
//   mongosh open5gs add_subscribers.js
//
// Or pipe remotely:
//   ssh saish@pc811.emulab.net "mongosh open5gs" < configs/add_subscribers.js
// =============================================================================

const K   = "00112233445566778899aabbccddeeff";
const OPC = "63bfa50ee6523365ff14c1f45f88737d";

function makeImsi(i) {
  return "99970" + String(i).padStart(10, "0");
}

function makeSubscriber(i) {
  const imsi = makeImsi(i);
  return {
    imsi: imsi,
    subscribed_rau_tau_timer: 12,
    network_access_mode: 2,
    subscriber_status: 0,
    access_restriction_data: 32,
    slice: [
      {
        sst: 1,
        default_indicator: true,
        session: [
          {
            name: "internet",
            type: 3,       // IPv4
            pcc_rule: [],
            ambr: { uplink: { value: 1, unit: 3 }, downlink: { value: 1, unit: 3 } },
            qos: {
              index: 9,
              arp: { priority_level: 8, pre_emption_capability: 1, pre_emption_vulnerability: 1 }
            }
          }
        ]
      }
    ],
    ambr: { uplink: { value: 1, unit: 3 }, downlink: { value: 1, unit: 3 } },
    security: {
      k:         K,
      op:        null,
      opc:       OPC,
      amf:       "8000",
      sqn:       NumberLong(0)
    },
    schema_version: 1,
    __v: 0
  };
}

// ── Insert or update each subscriber ─────────────────────────────────────────
let inserted = 0;
let updated  = 0;

for (let i = 1; i <= 110; i++) {
  const sub = makeSubscriber(i);
  const result = db.subscribers.updateOne(
    { imsi: sub.imsi },
    { $setOnInsert: sub },
    { upsert: true }
  );
  if (result.upsertedCount > 0) {
    inserted++;
  } else {
    updated++;
  }
}

print("==============================================");
print("  Subscribers inserted (new) : " + inserted);
print("  Subscribers already existed: " + updated);
print("  Total in DB                : " + db.subscribers.countDocuments());
print("==============================================");
print("IMSI range: " + makeImsi(1) + " – " + makeImsi(110));
