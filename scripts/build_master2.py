#!/usr/bin/env python3
"""
build_master2.py
Merges all collected CSVs from /tmp/ran_data2/ into a single master dataset.

Expected input files:
  gnb1_rich_metrics.csv     — per-UE RAN metrics from gnb1 logs + srsenb CSV
  ue_phy_metrics.csv        — per-UE RSRP, SNR, PCI, RSS from uehost1
  udp_latency_all_ues.csv   — per-UE per-rate UDP throughput + ICMP latency
  gnb1_sysmon.csv           — time-series system monitor from gnb1

Output: results/master_dataset_v2.csv
"""

import os
import sys
import pandas as pd
from pathlib import Path

DATA_DIR = Path("/tmp/ran_data2")
OUT_DIR  = Path("results")
OUT_FILE = OUT_DIR / "master_dataset_v2.csv"

OUT_DIR.mkdir(parents=True, exist_ok=True)

def load(name, required=True):
    p = DATA_DIR / name
    if not p.exists():
        if required:
            print(f"[WARN] Missing: {p}")
        return None
    try:
        df = pd.read_csv(p)
        print(f"[OK] {name}: {len(df)} rows × {len(df.columns)} cols")
        return df
    except Exception as e:
        print(f"[ERR] {name}: {e}")
        return None

# ── Load all sources ──────────────────────────────────────────────────────────
gnb_rich   = load("gnb1_rich_metrics.csv")
ue_phy     = load("ue_phy_metrics.csv")
udp_lat    = load("udp_latency_all_ues.csv")
gnb_sysmon = load("gnb1_sysmon.csv", required=False)

# ── Pivot UDP/latency table so each (ue_id) → wide row ───────────────────────
if udp_lat is not None:
    udp_lat["ue_id"] = udp_lat["ue_id"].astype(int)

    # Separate test types
    ping_base  = udp_lat[udp_lat["test_type"] == "ping_baseline"].copy()
    ping_load  = udp_lat[udp_lat["test_type"] == "ping_under_load"].copy()
    udp_ramp   = udp_lat[udp_lat["test_type"] == "udp_ramp"].copy()

    # Pivot UDP ramp: one col per rate per metric
    if not udp_ramp.empty:
        udp_pivot = udp_ramp.pivot_table(
            index="ue_id",
            columns="rate_target_mbps",
            values=["throughput_mbps", "jitter_ms", "pkt_loss_pct"],
            aggfunc="mean"
        )
        udp_pivot.columns = [f"{m}_at_{int(r)}mbps" for m, r in udp_pivot.columns]
        udp_pivot = udp_pivot.reset_index()
    else:
        udp_pivot = pd.DataFrame(columns=["ue_id"])

    # Baseline ping stats
    if not ping_base.empty:
        pb = ping_base[["ue_id", "ping_min_ms", "ping_avg_ms",
                         "ping_max_ms", "ping_mdev_ms", "ping_loss_pct"]].copy()
        pb.columns = ["ue_id"] + [f"baseline_{c}" for c in pb.columns[1:]]
    else:
        pb = pd.DataFrame(columns=["ue_id"])

    # Ping under load
    if not ping_load.empty:
        pl = ping_load[["ue_id", "ping_min_ms", "ping_avg_ms",
                         "ping_max_ms", "ping_mdev_ms", "ping_loss_pct"]].copy()
        pl.columns = ["ue_id"] + [f"loaded_{c}" for c in pl.columns[1:]]
    else:
        pl = pd.DataFrame(columns=["ue_id"])

    # Merge UDP/latency together
    udp_full = udp_pivot
    if not pb.empty:
        udp_full = udp_full.merge(pb, on="ue_id", how="outer") if not udp_full.empty else pb
    if not pl.empty:
        udp_full = udp_full.merge(pl, on="ue_id", how="outer") if not udp_full.empty else pl
else:
    udp_full = pd.DataFrame(columns=["ue_id"])

# ── Build per-UE master row ───────────────────────────────────────────────────
dfs = []
for src, key in [(gnb_rich, "ue_id"), (ue_phy, "ue_id")]:
    if src is not None:
        src["ue_id"] = src["ue_id"].astype(int)
        dfs.append(src)

if not dfs:
    print("[ERR] No UE-level data found. Exiting.")
    sys.exit(1)

master = dfs[0]
for df in dfs[1:]:
    # Avoid duplicate columns (keep left on conflict, suffix _phy for right)
    overlapping = [c for c in df.columns if c in master.columns and c != "ue_id"]
    master = master.merge(df, on="ue_id", how="outer",
                          suffixes=("", "_phy"))

if not udp_full.empty and "ue_id" in udp_full.columns:
    udp_full["ue_id"] = udp_full["ue_id"].astype(int)
    master = master.merge(udp_full, on="ue_id", how="outer")

master = master.sort_values("ue_id").reset_index(drop=True)

# ── Save ─────────────────────────────────────────────────────────────────────
master.to_csv(OUT_FILE, index=False)
print(f"\n[DONE] {OUT_FILE}: {len(master)} rows × {len(master.columns)} cols")

# Summary stats
print("\n── UDP throughput summary (Mbps) ──")
tp_cols = [c for c in master.columns if c.startswith("throughput_mbps_at_")]
if tp_cols:
    print(master[tp_cols].describe().round(3).to_string())

print("\n── Latency summary (ms) ──")
lat_cols = [c for c in master.columns if "ping_avg_ms" in c]
if lat_cols:
    print(master[lat_cols].describe().round(2).to_string())

print("\n── RAN summary ──")
ran_cols = [c for c in master.columns if c in
            ["pucch_snr_db", "pucch_cqi", "pdsch_nof_prb", "prb_util_pct",
             "pusch_snr_db", "pusch_mcs", "pdsch_mcs"]]
if ran_cols:
    print(master[ran_cols].describe().round(2).to_string())

# ── Also save gnb1 sysmon as separate timeseries ──────────────────────────────
if gnb_sysmon is not None:
    sysmon_out = OUT_DIR / "gnb1_sysmon_timeseries.csv"
    gnb_sysmon.to_csv(sysmon_out, index=False)
    print(f"\n[SAVED] {sysmon_out}: {len(gnb_sysmon)} rows × {len(gnb_sysmon.columns)} cols")
