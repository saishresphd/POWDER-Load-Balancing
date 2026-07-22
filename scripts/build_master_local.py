#!/usr/bin/env python3
"""
build_master_local.py
Merges all locally-downloaded node CSVs into one master dataset.
Run: python3 scripts/build_master_local.py
"""
import csv, io, os, sys
from collections import defaultdict

DATA_DIR = "/tmp/ran_data"
OUT_FILE = "results/master_dataset.csv"
os.makedirs("results", exist_ok=True)


def load(path, delim=","):
    if not os.path.exists(path):
        print(f"  MISSING: {path}")
        return []
    with open(path) as f:
        rows = list(csv.DictReader(f, delimiter=delim))
    print(f"  {os.path.basename(path):30s} {len(rows):5d} rows")
    return rows


def bucket(ts, step=2):
    import re
    m = re.match(r'(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}):(\d{2})Z', str(ts))
    if not m:
        return str(ts)
    base, sec = m.group(1), int(m.group(2))
    return f"{base}:{(sec//step)*step:02d}Z"


master = defaultdict(dict)

SYS_COLS = ["cpu_pct","cpu_user","cpu_sys","cpu_iowait","cpu_freq_mhz",
            "num_cpus","mem_used_mb","mem_total_mb","mem_free_mb","mem_cache_mb",
            "load1","load5","load15","running_procs","total_procs",
            "temp_c","irq_count","ctxt_count","rx_bytes","tx_bytes",
            "srsenb_count","srsue_count","power_w"]

GNB_COLS = ["nof_ue","dl_brate_mbps","ul_brate_mbps","dl_nof_ok","dl_nof_nok",
            "ul_nof_ok","ul_nof_nok","phr","last_ta","sys_load"]

print("Loading system metrics...")
for node, fname in [("core","sys_core.csv"), ("gnb1","sys_gnb1.csv"),
                    ("gnb2","sys_gnb2.csv"), ("uehost1","sys_uehost1.csv"),
                    ("uehost2","sys_uehost2.csv")]:
    for row in load(f"{DATA_DIR}/{fname}"):
        ts = bucket(row.get("timestamp",""))
        for c in SYS_COLS:
            v = row.get(c,"")
            if v and v not in ("N/A",""):
                master[ts][f"{node}_{c}"] = v

print("\nLoading gNB metrics...")
for gnb, fname in [("gnb1","gnb_gnb1.csv"), ("gnb2","gnb_gnb2.csv")]:
    for row in load(f"{DATA_DIR}/{fname}"):
        ts   = bucket(row.get("timestamp",""))
        slot = row.get("ue_slot","")
        if not slot:
            continue
        for c in GNB_COLS:
            v = row.get(c,"")
            if v and v not in ("N/A",""):
                master[ts][f"{gnb}_ue{slot}_{c}"] = v

print("\nLoading attach log...")
ue_info = {}
for row in load(f"{DATA_DIR}/attach_log.csv"):
    uid = row.get("ue_id","")
    if uid:
        ue_info[uid] = {
            "status":      row.get("status",""),
            "ip_address":  row.get("ip_address",""),
            "attach_sec":  row.get("attach_sec",""),
        }
print(f"  {len(ue_info)} UE attach entries")

# Stamp every time bucket with UE attach info
for ts in master:
    for uid, info in ue_info.items():
        master[ts][f"ue{uid}_status"]     = info["status"]
        master[ts][f"ue{uid}_ip_address"] = info["ip_address"]
        master[ts][f"ue{uid}_attach_sec"] = info["attach_sec"]

if not master:
    print("ERROR: no data"); sys.exit(1)

# Build column order
all_keys = set()
for v in master.values():
    all_keys.update(v.keys())

def sort_key(k):
    import re
    order = ["core_","gnb1_ue","gnb2_ue","gnb1_","gnb2_","uehost1_","uehost2_","ue"]
    for i, p in enumerate(order):
        if k.startswith(p):
            nums = re.findall(r'\d+', k)
            return (i, int(nums[0]) if nums else 0, k)
    return (99, 0, k)

fieldnames = ["timestamp"] + sorted(all_keys, key=sort_key)

with open(OUT_FILE, "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore", restval="")
    w.writeheader()
    written = 0
    for ts in sorted(master.keys()):
        row = {"timestamp": ts}
        row.update(master[ts])
        w.writerow(row)
        written += 1

size = os.path.getsize(OUT_FILE)
print(f"\n{'='*60}")
print(f"Output : {OUT_FILE}")
print(f"Rows   : {written}")
print(f"Columns: {len(fieldnames)}")
print(f"Size   : {size//1024} KB")
print(f"{'='*60}")

# ── Column group summary ──
groups = {}
for k in fieldnames:
    if k == "timestamp": continue
    if k.startswith("gnb") and "_ue" in k and "_ue" in k:
        p = k.split("_ue")[0] + "_ue*"
    else:
        p = k.split("_")[0]
    groups[p] = groups.get(p, 0) + 1
print("\nColumn groups:")
for g, cnt in sorted(groups.items()):
    print(f"  {g:22s} {cnt:4d} cols")
