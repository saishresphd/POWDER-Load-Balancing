#!/usr/bin/env python3
"""
build_master_csv.py
Pull all per-node CSVs via SSH and merge into one wide master CSV.
Run locally after collect_100s.sh completes on all nodes.

Output: results/master_dataset.csv
Columns:
  timestamp,
  -- system per node (5 nodes) --
  {node}_cpu_pct, {node}_cpu_user, {node}_cpu_sys, {node}_cpu_iowait,
  {node}_cpu_freq_mhz, {node}_num_cpus,
  {node}_mem_used_mb, {node}_mem_total_mb, {node}_mem_free_mb, {node}_mem_cache_mb,
  {node}_load1, {node}_load5, {node}_load15,
  {node}_running_procs, {node}_total_procs,
  {node}_temp_c, {node}_irq_count, {node}_ctxt_count,
  {node}_rx_bytes, {node}_tx_bytes,
  {node}_srsenb_count, {node}_srsue_count, {node}_power_w,
  -- gNB slot metrics (50 UE slots on gnb1, 50 on gnb2) --
  gnb{1|2}_ue{N}_nof_ue, gnb{1|2}_ue{N}_dl_brate_mbps,
  gnb{1|2}_ue{N}_ul_brate_mbps, gnb{1|2}_ue{N}_dl_nof_ok,
  gnb{1|2}_ue{N}_dl_nof_nok, gnb{1|2}_ue{N}_ul_nof_ok,
  gnb{1|2}_ue{N}_ul_nof_nok, gnb{1|2}_ue{N}_phr,
  gnb{1|2}_ue{N}_last_ta, gnb{1|2}_ue{N}_sys_load,
  -- UE attach info --
  ue{N}_status, ue{N}_ip, ue{N}_attach_time_sec
"""

import argparse, csv, io, os, subprocess, sys
from collections import defaultdict

NODES = {
    "core":    "saish@pc811.emulab.net",
    "gnb1":    "saish@pc818.emulab.net",
    "gnb2":    "saish@pc802.emulab.net",
    "uehost1": "saish@pc808.emulab.net",
    "uehost2": "saish@pc801.emulab.net",
}
COLLECT = "/tmp/ran_collect"


def ssh_cat(host, path):
    r = subprocess.run(
        ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=10",
         host, f"cat {path} 2>/dev/null"],
        capture_output=True, text=True, timeout=60
    )
    return r.stdout


def parse_csv(raw, delim=","):
    raw = raw.strip()
    if not raw:
        return []
    try:
        return list(csv.DictReader(io.StringIO(raw), delimiter=delim))
    except Exception:
        return []


def bucket(ts, step=2):
    """Round timestamp down to nearest step-second bucket for alignment."""
    import re, datetime
    m = re.match(r'(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}):(\d{2})Z', ts)
    if not m:
        return ts
    base, sec = m.group(1), int(m.group(2))
    snapped = (sec // step) * step
    return f"{base}:{snapped:02d}Z"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--output", default="results/master_dataset.csv")
    args = ap.parse_args()
    os.makedirs(os.path.dirname(args.output) or ".", exist_ok=True)

    master = defaultdict(dict)   # {timestamp_bucket: {col: val}}

    # ── 1. System metrics ──────────────────────────────────────────────
    SYS_COLS = ["cpu_pct","cpu_user","cpu_sys","cpu_iowait","cpu_freq_mhz",
                "num_cpus","mem_used_mb","mem_total_mb","mem_free_mb",
                "mem_cache_mb","load1","load5","load15","running_procs",
                "total_procs","temp_c","irq_count","ctxt_count",
                "rx_bytes","tx_bytes","srsenb_count","srsue_count","power_w"]

    for node, host in NODES.items():
        raw = ssh_cat(host, f"{COLLECT}/sys_{node}.csv")
        rows = parse_csv(raw)
        print(f"  {node:9s}: {len(rows):4d} system rows")
        for row in rows:
            ts = bucket(row.get("timestamp", ""))
            for col in SYS_COLS:
                v = row.get(col, "")
                if v and v != "N/A":
                    master[ts][f"{node}_{col}"] = v

    # ── 2. gNB slot metrics ────────────────────────────────────────────
    GNB_COLS = ["nof_ue","dl_brate_mbps","ul_brate_mbps","dl_nof_ok",
                "dl_nof_nok","ul_nof_ok","ul_nof_nok","phr","last_ta","sys_load"]

    for gnb, host, ue_range in [
        ("gnb1", NODES["gnb1"], range(1,  51)),
        ("gnb2", NODES["gnb2"], range(51, 101)),
    ]:
        raw = ssh_cat(host, f"{COLLECT}/gnb_{gnb}.csv")
        rows = parse_csv(raw)
        print(f"  {gnb:9s}: {len(rows):4d} gNB slot rows")
        for row in rows:
            ts   = bucket(row.get("timestamp", ""))
            slot = row.get("ue_slot", "")
            if not slot:
                continue
            for col in GNB_COLS:
                v = row.get(col, "")
                if v:
                    master[ts][f"{gnb}_ue{slot}_{col}"] = v

    # ── 3. UE attach log ───────────────────────────────────────────────
    # Pull attach_log.csv from uehost1 and uehost2
    ue_info = {}   # ue_id → {status, ip, attach_time}
    for host in [NODES["uehost1"], NODES["uehost2"]]:
        raw = ssh_cat(host, f"{COLLECT}/attach_log.csv")
        rows = parse_csv(raw)
        for row in rows:
            uid = row.get("ue_id","")
            if uid:
                ue_info[uid] = {
                    "status":      row.get("status",""),
                    "ip":          row.get("ip_address",""),
                    "attach_time": row.get("attach_time_sec",""),
                }

    print(f"  attach_log: {len(ue_info)} UE entries")

    # Inject UE attach info into every timestamp row
    for ts in master:
        for uid, info in ue_info.items():
            master[ts][f"ue{uid}_status"]      = info["status"]
            master[ts][f"ue{uid}_ip"]          = info["ip"]
            master[ts][f"ue{uid}_attach_time"] = info["attach_time"]

    if not master:
        print("ERROR: no data found. Run collect_100s.sh on nodes first.")
        sys.exit(1)

    # ── 4. Sort fieldnames ─────────────────────────────────────────────
    all_keys = set()
    for v in master.values():
        all_keys.update(v.keys())

    def _sort_key(k):
        order = ["core_","gnb1_ue","gnb2_ue","gnb1_","gnb2_",
                 "uehost1_","uehost2_","ue"]
        for i, p in enumerate(order):
            if k.startswith(p):
                # numeric sort within ue slots
                import re
                nums = re.findall(r'\d+', k)
                return (i, int(nums[0]) if nums else 0, k)
        return (99, 0, k)

    fieldnames = ["timestamp"] + sorted(all_keys, key=_sort_key)

    # ── 5. Write ───────────────────────────────────────────────────────
    with open(args.output, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames,
                           extrasaction="ignore", restval="")
        w.writeheader()
        for ts in sorted(master.keys()):
            row = {"timestamp": ts}
            row.update(master[ts])
            w.writerow(row)

    n_rows = len(master)
    n_cols = len(fieldnames)
    size   = os.path.getsize(args.output)

    print(f"\n✅  {args.output}")
    print(f"   {n_rows} rows  ×  {n_cols} columns  ({size//1024} KB)")
    print("\nColumn summary:")
    groups = {}
    for k in fieldnames:
        if k == "timestamp": continue
        prefix = k.split("_")[0] if not k.startswith("gnb") else "_".join(k.split("_")[:2])
        if k.startswith("gnb") and "_ue" in k:
            prefix = k.split("_ue")[0] + "_ue*"
        groups[prefix] = groups.get(prefix, 0) + 1
    for g, cnt in sorted(groups.items()):
        print(f"  {g:20s} {cnt:4d} columns")


if __name__ == "__main__":
    main()
