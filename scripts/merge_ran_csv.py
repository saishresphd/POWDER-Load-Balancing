#!/usr/bin/env python3
"""
merge_ran_csv.py  —  Master CSV assembler
==========================================
Runs on the LOCAL machine (laptop / jump host).
Pulls per-node CSV fragments via SSH and joins them on the nearest
timestamp into a single wide CSV.

Output columns (in order):
  timestamp,phase,
  -- per UE (1-50 gNB1, 51-100 gNB2) --
  ue{N}_attached, ue{N}_ip,
  ue{N}_iperf_dl_mbps, ue{N}_iperf_ul_mbps,
  -- per gNB slot --
  gnb{G}_ue{N}_nof_ue, gnb{G}_ue{N}_dl_brate, gnb{G}_ue{N}_ul_brate,
  gnb{G}_ue{N}_dl_nof_ok, gnb{G}_ue{N}_ul_nof_ok, gnb{G}_ue{N}_dl_nof_nok,
  gnb{G}_ue{N}_ul_nof_nok, gnb{G}_ue{N}_phr, gnb{G}_ue{N}_last_ta,
  -- per node system metrics --
  {node}_cpu_pct, {node}_cpu_freq_mhz, {node}_mem_used_mb,
  {node}_mem_total_mb, {node}_load1, {node}_load5, {node}_load15,
  {node}_temp_c, {node}_irq_rate, {node}_ipc, {node}_power_w
  (nodes: core, gnb1, gnb2, uehost1, uehost2)

Usage:
  python3 scripts/merge_ran_csv.py --output results/master_dataset.csv
"""

import argparse, csv, datetime, io, os, subprocess, sys, time
from collections import defaultdict

NODES = {
    "core":    "saish@pc811.emulab.net",
    "gnb1":    "saish@pc818.emulab.net",
    "gnb2":    "saish@pc802.emulab.net",
    "uehost1": "saish@pc808.emulab.net",
    "uehost2": "saish@pc801.emulab.net",
}

COLLECT_DIR = "/tmp/ran_collect"
MASTER_HEADER_FILE = "/tmp/master_header.txt"


def ssh(host, cmd, timeout=30):
    result = subprocess.run(
        ["ssh", "-o", "StrictHostKeyChecking=no",
         "-o", "ConnectTimeout=10", host, cmd],
        capture_output=True, text=True, timeout=timeout
    )
    return result.stdout.strip()


def pull_csv(host, remote_path):
    result = subprocess.run(
        ["ssh", "-o", "StrictHostKeyChecking=no", host,
         f"cat {remote_path} 2>/dev/null"],
        capture_output=True, text=True, timeout=30
    )
    return result.stdout


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", default="results/master_dataset.csv")
    parser.add_argument("--interval", type=int, default=5,
                        help="Merge interval in seconds")
    args = parser.parse_args()

    os.makedirs(os.path.dirname(args.output) or ".", exist_ok=True)

    print(f"[merge] Pulling CSVs from all nodes into {args.output}")
    rows = []

    for node, host in NODES.items():
        raw = pull_csv(host, f"{COLLECT_DIR}/system_metrics.csv")
        if not raw:
            print(f"  [WARN] No system_metrics.csv from {node}")
            continue
        reader = csv.DictReader(io.StringIO(raw))
        for row in reader:
            row["_node"] = node
            rows.append(row)

    if not rows:
        print("[merge] No data collected yet. Run collect_all.sh on nodes first.")
        sys.exit(1)

    # Group by timestamp (round to nearest 5s)
    buckets = defaultdict(dict)
    for row in rows:
        ts = row.get("timestamp", "")
        node = row.pop("_node")
        for k, v in row.items():
            buckets[ts][f"{node}_{k}"] = v

    # Pull gNB metrics CSVs
    for gnb, host, slots in [
        ("gnb1", NODES["gnb1"], range(1, 51)),
        ("gnb2", NODES["gnb2"], range(51, 101)),
    ]:
        for i in slots:
            raw = pull_csv(host, f"/tmp/{gnb}_ue{i}_metrics.csv")
            if not raw:
                continue
            reader = csv.DictReader(io.StringIO(raw), delimiter=";")
            for row in reader:
                ts = row.get("timestamp", row.get("TTI", ""))
                for k, v in row.items():
                    buckets[ts][f"{gnb}_ue{i}_{k}"] = v

    # Pull iperf results
    for host_label, host in [("uehost1", NODES["uehost1"]),
                               ("uehost2", NODES["uehost2"])]:
        raw = pull_csv(host, f"{COLLECT_DIR}/iperf_results.csv")
        if not raw:
            continue
        reader = csv.DictReader(io.StringIO(raw))
        for row in reader:
            ts = row.get("timestamp", "")
            ue = row.get("ue_id", "")
            for k, v in row.items():
                buckets[ts][f"ue{ue}_{k}"] = v

    if not buckets:
        print("[merge] Buckets empty.")
        sys.exit(1)

    all_keys = set()
    for b in buckets.values():
        all_keys.update(b.keys())
    fieldnames = ["timestamp"] + sorted(all_keys - {"timestamp"})

    with open(args.output, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        for ts in sorted(buckets.keys()):
            row = {"timestamp": ts}
            row.update(buckets[ts])
            writer.writerow(row)

    print(f"[merge] Written {len(buckets)} rows × {len(fieldnames)} columns → {args.output}")


if __name__ == "__main__":
    main()
