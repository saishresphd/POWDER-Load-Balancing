#!/usr/bin/env python3
"""
collect_rich_gnb1.py  —  Fast log parser for gnb1 rich RAN metrics
Reads /tmp/gnb1_logs/ueN.log and /tmp/gnb1_ueN_metrics.csv for each UE slot.
Extracts:
  PUCCH: snr, cqi, ta  (last valid line)
  PUSCH: snr, mcs, tbs, ta, nof_re  (last crc=OK line)
  PDSCH: nof_prb, nof_re, mcs, tbs  (last line for this UE rnti)
  srsenb CSV: dl_brate, ul_brate, proc_rss_kB, proc_vmem_kB, sys_mem, sys_load,
              thread_count, cpu_max, cpu_mean, cpu_p95
Output: /tmp/ran_collect/gnb1_rich_metrics.csv
"""

import re
import os
import csv
import sys
from pathlib import Path
from statistics import mean, stdev

LOG_DIR    = Path("/tmp/gnb1_logs")
METRIC_DIR = Path("/tmp")
OUT_FILE   = Path("/tmp/ran_collect/gnb1_rich_metrics.csv")
OUT_FILE.parent.mkdir(parents=True, exist_ok=True)

# Regex patterns
RE_PUCCH = re.compile(
    r'(\S+).*PUCCH:.*rnti=(0x[0-9a-f]+).*snr=([0-9.-]+) dB.*cqi=(\d+).*ta=([0-9.-]+) us'
)
RE_PUSCH = re.compile(
    r'(\S+).*PUSCH:.*rnti=(0x[0-9a-f]+).*nof_re=(\d+).*tbs=(\d+).*mod=(\d+).*crc=OK.*snr=([0-9.-]+) dB.*ta=([0-9.-]+) us'
)
RE_PDSCH = re.compile(
    r'(\S+).*PDSCH:.*rnti=(0x[0-9a-f]+).*nof_prb=(\d+).*nof_re=(\d+).*tbs=\{?(\d+)\}?.*mod=\{?(\d+)\}?'
)

FIELDS = [
    "ue_id","timestamp",
    "pucch_snr_db","pucch_cqi","pucch_ta_us",
    "pusch_snr_db","pusch_mcs","pusch_tbs","pusch_nof_re","pusch_ta_us",
    "pdsch_nof_prb","pdsch_nof_re","pdsch_mcs","pdsch_tbs",
    "prb_util_pct",
    "dl_brate_bps","ul_brate_bps",
    "proc_rss_kB","proc_vmem_kB","sys_mem_pct","sys_load","thread_count",
    "cpu_max","cpu_mean","cpu_p95"
]

def parse_log(log_path):
    """Read last valid PUCCH/PUSCH/PDSCH lines for a given UE log file."""
    pucch = {}
    pusch = {}
    pdsch = {}
    ue_rnti = None
    # Scan file in chunks from end using reversed iteration on lines
    # For large files read tail of file only (last 50000 lines is plenty)
    try:
        with open(log_path, "r", errors="replace") as f:
            lines = f.readlines()
    except Exception as e:
        print(f"  [WARN] cannot read {log_path}: {e}", file=sys.stderr)
        return {}, {}, {}

    # Scan tail first (most recent data)
    tail = lines[-5000:] if len(lines) > 5000 else lines

    for line in reversed(tail):
        if not pucch:
            m = RE_PUCCH.search(line)
            if m:
                pucch = dict(ts=m.group(1), rnti=m.group(2),
                             snr=m.group(3), cqi=m.group(4), ta=m.group(5))
                if ue_rnti is None:
                    ue_rnti = m.group(2)
        if not pusch:
            m = RE_PUSCH.search(line)
            if m:
                pusch = dict(ts=m.group(1), rnti=m.group(2),
                             nof_re=m.group(3), tbs=m.group(4),
                             mcs=m.group(5), snr=m.group(6), ta=m.group(7))
                if ue_rnti is None:
                    ue_rnti = m.group(2)
        if not pdsch and ue_rnti:
            m = RE_PDSCH.search(line)
            if m and m.group(2) == ue_rnti:
                pdsch = dict(ts=m.group(1), rnti=m.group(2),
                             nof_prb=m.group(3), nof_re=m.group(4),
                             tbs=m.group(5), mcs=m.group(6))
        if pucch and pusch and pdsch:
            break

    # If we still need pdsch rnti, try head of file
    if not ue_rnti:
        for line in lines[:500]:
            m = re.search(r'rnti=(0x[0-9a-f]+)', line)
            if m and m.group(1) != '0x2':
                ue_rnti = m.group(1)
                break

    if not pdsch and ue_rnti:
        for line in reversed(tail):
            m = RE_PDSCH.search(line)
            if m and m.group(2) == ue_rnti:
                pdsch = dict(ts=m.group(1), rnti=m.group(2),
                             nof_prb=m.group(3), nof_re=m.group(4),
                             tbs=m.group(5), mcs=m.group(6))
                break

    return pucch, pusch, pdsch

def parse_metrics_csv(csv_path):
    """Read last row of srsenb metrics CSV."""
    result = {}
    try:
        with open(csv_path, "r") as f:
            lines = [l.strip() for l in f if l.strip()]
        if len(lines) < 2:
            return result
        # Last data row
        last = lines[-1].split(";")
        # cols: time;nof_ue;dl_brate;ul_brate;proc_rmem;proc_rmem_kB;proc_vmem_kB;
        #        sys_mem;system_load;thread_count;cpu_0..cpu_31
        if len(last) < 10:
            return result
        result["dl_brate"]     = last[2]
        result["ul_brate"]     = last[3]
        result["proc_rss_kB"]  = last[5]
        result["proc_vmem_kB"] = last[6]
        result["sys_mem"]      = last[7]
        result["sys_load"]     = last[8]
        result["thread_count"] = last[9]
        # CPU cores: index 10 onwards
        cpu_raw = last[10:]
        try:
            cpus = [float(v) for v in cpu_raw if v.strip() not in ('', 'nan', 'NA')]
            if cpus:
                result["cpu_max"]  = f"{max(cpus):.2f}"
                result["cpu_mean"] = f"{mean(cpus):.2f}"
                sorted_c = sorted(cpus)
                p95_idx  = int(len(sorted_c) * 0.95)
                result["cpu_p95"] = f"{sorted_c[p95_idx]:.2f}"
        except Exception:
            pass
    except Exception as e:
        print(f"  [WARN] metrics CSV {csv_path}: {e}", file=sys.stderr)
    return result

# ── Main ──────────────────────────────────────────────────────────────────────
with open(OUT_FILE, "w", newline="") as fout:
    writer = csv.DictWriter(fout, fieldnames=FIELDS)
    writer.writeheader()

    for i in range(1, 51):
        log_path    = LOG_DIR / f"ue{i}.log"
        metric_path = METRIC_DIR / f"gnb1_ue{i}_metrics.csv"

        row = {f: "NA" for f in FIELDS}
        row["ue_id"] = i

        if not log_path.exists():
            print(f"  [SKIP] ue{i}: no log file")
            writer.writerow(row)
            continue

        print(f"  [ue{i}] parsing {log_path.stat().st_size//1024//1024}MB log...")
        pucch, pusch, pdsch = parse_log(log_path)

        # Timestamp — use most recent available
        ts = (pucch.get("ts") or pusch.get("ts") or pdsch.get("ts") or "NA")
        row["timestamp"] = ts

        # PUCCH
        if pucch:
            row["pucch_snr_db"] = pucch.get("snr", "NA")
            row["pucch_cqi"]    = pucch.get("cqi", "NA")
            row["pucch_ta_us"]  = pucch.get("ta",  "NA")

        # PUSCH
        if pusch:
            row["pusch_snr_db"] = pusch.get("snr",    "NA")
            row["pusch_mcs"]    = pusch.get("mcs",    "NA")
            row["pusch_tbs"]    = pusch.get("tbs",    "NA")
            row["pusch_nof_re"] = pusch.get("nof_re", "NA")
            row["pusch_ta_us"]  = pusch.get("ta",     "NA")

        # PDSCH
        if pdsch:
            row["pdsch_nof_prb"] = pdsch.get("nof_prb", "NA")
            row["pdsch_nof_re"]  = pdsch.get("nof_re",  "NA")
            row["pdsch_mcs"]     = pdsch.get("mcs",     "NA")
            row["pdsch_tbs"]     = pdsch.get("tbs",     "NA")
            try:
                prb = int(pdsch["nof_prb"])
                row["prb_util_pct"] = f"{(prb/50.0)*100:.2f}"
            except Exception:
                pass

        # srsenb metrics CSV
        if metric_path.exists():
            m = parse_metrics_csv(metric_path)
            row["dl_brate_bps"]  = m.get("dl_brate",     "NA")
            row["ul_brate_bps"]  = m.get("ul_brate",     "NA")
            row["proc_rss_kB"]   = m.get("proc_rss_kB",  "NA")
            row["proc_vmem_kB"]  = m.get("proc_vmem_kB", "NA")
            row["sys_mem_pct"]   = m.get("sys_mem",      "NA")
            row["sys_load"]      = m.get("sys_load",     "NA")
            row["thread_count"]  = m.get("thread_count", "NA")
            row["cpu_max"]       = m.get("cpu_max",      "NA")
            row["cpu_mean"]      = m.get("cpu_mean",     "NA")
            row["cpu_p95"]       = m.get("cpu_p95",      "NA")

        writer.writerow(row)
        print(f"    pucch_snr={row['pucch_snr_db']} cqi={row['pucch_cqi']} "
              f"pdsch_prb={row['pdsch_nof_prb']} prb_util={row['prb_util_pct']}%")

print(f"\n[DONE] {OUT_FILE}")
import subprocess
result = subprocess.run(["wc", "-l", str(OUT_FILE)], capture_output=True, text=True)
print(result.stdout.strip())
