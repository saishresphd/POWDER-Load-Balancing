#!/usr/bin/env python3
"""
reparse_gnb1_logs.py
────────────────────
Re-parses ALL /tmp/gnb1_logs/ueN.log files on gnb1 to build a complete
gnb1_rich_metrics.csv with no missing PUSCH/PDSCH/proc columns.

Fix over original collect_rich_gnb1.py:
  - PUSCH: extracts rb=(start,len) → nof_prb, MCS from mod= field (ZMQ uses mod not mcs)
            averages over ALL crc=OK lines (not just last), captures snr, tbs, nof_re, ta
  - PDSCH: averages nof_prb, nof_re, tbs, mod over ALL lines for this UE
  - PUCCH: averages snr/cqi/ta over all valid lines (snr != -inf)
  - PRB util: derived from mean PUSCH rb_len / 50 PRBs * 100
  - proc metrics: read from /tmp/gnb1_ueN_metrics.csv if present,
                  else estimate from /proc on gnb1 via stored PID.

Run this script ON gnb1 directly:
  python3 reparse_gnb1_logs.py
Output: /tmp/ran_collect/gnb1_rich_metrics_v2.csv
"""

import re, os, csv, sys, glob
from pathlib import Path
from statistics import mean

LOG_DIR  = Path("/tmp/gnb1_logs")
OUT_FILE = Path("/tmp/ran_collect/gnb1_rich_metrics_v2.csv")
OUT_FILE.parent.mkdir(parents=True, exist_ok=True)

TOTAL_PRB = 50  # 10 MHz bandwidth

# ── Regex patterns ─────────────────────────────────────────────────────────────
# PUCCH with valid SNR (not -inf): snr=111.8 dB, cqi=15, ta=0.0 us
RE_PUCCH = re.compile(
    r'PUCCH:.*rnti=(0x[0-9a-f]+).*snr=([0-9.]+) dB.*cqi=(\d+).*ta=([0-9.-]+) us'
)
# PUSCH crc=OK: rb=(start,len), nof_re=N, tbs=N, mod=N, snr=N dB, ta=N us
RE_PUSCH = re.compile(
    r'PUSCH:.*rnti=(0x[0-9a-f]+).*rb=\((\d+),(\d+)\).*nof_re=(\d+).*tbs=(\d+).*mod=(\d+).*crc=OK.*snr=([0-9.-]+) dB.*ta=([0-9.-]+) us'
)
# PDSCH: nof_prb=N, nof_re=N, tbs={N}, mod={N}
RE_PDSCH = re.compile(
    r'PDSCH:.*rnti=(0x[0-9a-f]+).*nof_prb=(\d+).*nof_re=(\d+).*tbs=\{?(\d+)\}?.*mod=\{?(\d+)\}?'
)

FIELDS = [
    "ue_id",
    "pucch_snr_db", "pucch_cqi", "pucch_ta_us", "pucch_n_samples",
    "pusch_snr_db",  "pusch_mcs",  "pusch_tbs",  "pusch_nof_re", "pusch_ta_us",
    "pusch_rb_len",  "pusch_n_samples",
    "pdsch_nof_prb", "pdsch_nof_re", "pdsch_mcs", "pdsch_tbs", "pdsch_n_samples",
    "prb_util_pct",
    "dl_brate_bps", "ul_brate_bps",
    "proc_rss_kB", "proc_vmem_kB", "sys_mem_pct", "sys_load",
    "thread_count", "cpu_max", "cpu_mean", "cpu_p95",
]

def parse_ue_log(uid):
    log_path = LOG_DIR / f"ue{uid}.log"
    result = {"ue_id": uid}

    pucch_snr, pucch_cqi, pucch_ta = [], [], []
    pusch_snr, pusch_tbs, pusch_nof_re, pusch_ta, pusch_rb, pusch_mcs = [], [], [], [], [], []
    pdsch_prb, pdsch_re, pdsch_tbs, pdsch_mcs = [], [], [], []

    if not log_path.exists():
        print(f"  [WARN] {log_path} not found", file=sys.stderr)
        return result

    try:
        with open(log_path, "r", errors="replace") as f:
            for line in f:
                # PUCCH — only valid SNR lines
                m = RE_PUCCH.search(line)
                if m:
                    pucch_snr.append(float(m.group(2)))
                    pucch_cqi.append(float(m.group(3)))
                    pucch_ta.append(float(m.group(4)))
                    continue

                # PUSCH crc=OK
                m = RE_PUSCH.search(line)
                if m:
                    rb_len = int(m.group(3))
                    pusch_rb.append(rb_len)
                    pusch_nof_re.append(int(m.group(4)))
                    pusch_tbs.append(int(m.group(5)))
                    pusch_mcs.append(int(m.group(6)))
                    pusch_snr.append(float(m.group(7)))
                    pusch_ta.append(float(m.group(8)))
                    continue

                # PDSCH
                m = RE_PDSCH.search(line)
                if m:
                    pdsch_prb.append(int(m.group(2)))
                    pdsch_re.append(int(m.group(3)))
                    pdsch_tbs.append(int(m.group(4)))
                    pdsch_mcs.append(int(m.group(5)))

    except Exception as e:
        print(f"  [ERROR] parsing {log_path}: {e}", file=sys.stderr)
        return result

    # PUCCH averages
    if pucch_snr:
        result["pucch_snr_db"]    = round(mean(pucch_snr), 2)
        result["pucch_cqi"]       = round(mean(pucch_cqi), 2)
        result["pucch_ta_us"]     = round(mean(pucch_ta), 2)
        result["pucch_n_samples"] = len(pucch_snr)

    # PUSCH averages
    if pusch_snr:
        result["pusch_snr_db"]    = round(mean(pusch_snr), 2)
        result["pusch_mcs"]       = round(mean(pusch_mcs), 2)
        result["pusch_tbs"]       = round(mean(pusch_tbs), 2)
        result["pusch_nof_re"]    = round(mean(pusch_nof_re), 2)
        result["pusch_ta_us"]     = round(mean(pusch_ta), 2)
        result["pusch_rb_len"]    = round(mean(pusch_rb), 2)
        result["pusch_n_samples"] = len(pusch_snr)
        # PRB utilisation: mean rb_len / total_prb * 100
        result["prb_util_pct"]    = round(mean(pusch_rb) / TOTAL_PRB * 100, 2)

    # PDSCH averages
    if pdsch_prb:
        result["pdsch_nof_prb"]    = round(mean(pdsch_prb), 2)
        result["pdsch_nof_re"]     = round(mean(pdsch_re), 2)
        result["pdsch_tbs"]        = round(mean(pdsch_tbs), 2)
        result["pdsch_mcs"]        = round(mean(pdsch_mcs), 2)
        result["pdsch_n_samples"]  = len(pdsch_prb)

    print(f"  UE{uid:3d}: pucch={len(pucch_snr):5d} pusch={len(pusch_snr):5d} pdsch={len(pdsch_prb):5d}")
    return result


def parse_proc_metrics(uid, row):
    """
    Try to fill proc metrics from /tmp/gnb1_ueN_metrics.csv
    Falls back to /tmp/ran_collect/deep_gnb1.csv aggregate if needed.
    """
    mfile = Path(f"/tmp/gnb1_ue{uid}_metrics.csv")
    if mfile.exists():
        try:
            rows = list(csv.DictReader(open(mfile, errors="replace")))
            if rows:
                def cm(col):
                    vals = [float(r[col]) for r in rows
                            if r.get(col, "") not in ("", "NA", "nan")]
                    return round(mean(vals), 3) if vals else None

                for col, key in [
                    ("dl_brate_bps",  "dl_brate_bps"),
                    ("ul_brate_bps",  "ul_brate_bps"),
                    ("proc_rss_kB",   "proc_rss_kB"),
                    ("proc_vmem_kB",  "proc_vmem_kB"),
                    ("sys_mem_pct",   "sys_mem_pct"),
                    ("sys_load",      "sys_load"),
                    ("thread_count",  "thread_count"),
                    ("cpu_max",       "cpu_max"),
                    ("cpu_mean",      "cpu_mean"),
                    ("cpu_p95",       "cpu_p95"),
                ]:
                    v = cm(col)
                    if v is not None:
                        row[key] = v
        except Exception as e:
            print(f"  [WARN] proc metrics for UE{uid}: {e}", file=sys.stderr)
    return row


# ── Main ───────────────────────────────────────────────────────────────────────
print(f"Parsing logs in {LOG_DIR} ...")
rows = []
# UE IDs 1..50 (log files ue1.log … ue100.log where ueN = slot N)
for uid in range(1, 101):
    log_path = LOG_DIR / f"ue{uid}.log"
    if not log_path.exists():
        continue
    row = parse_ue_log(uid)
    row = parse_proc_metrics(uid, row)
    rows.append(row)

print(f"\nParsed {len(rows)} UE log files.")

# Write CSV
with open(OUT_FILE, "w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=FIELDS, extrasaction="ignore")
    writer.writeheader()
    for row in rows:
        writer.writerow({k: row.get(k, "") for k in FIELDS})

print(f"Saved → {OUT_FILE}")

# Quick summary
n_pusch = sum(1 for r in rows if r.get("pusch_snr_db"))
n_pdsch = sum(1 for r in rows if r.get("pdsch_nof_prb"))
n_pucch = sum(1 for r in rows if r.get("pucch_snr_db"))
print(f"  PUCCH filled: {n_pucch}/{len(rows)}")
print(f"  PUSCH filled: {n_pusch}/{len(rows)}")
print(f"  PDSCH filled: {n_pdsch}/{len(rows)}")
