#!/usr/bin/env python3
"""
merge_per_ue_power.py
─────────────────────
Merges per_ue_power.csv into master_dataset_v4.csv to produce master_dataset_v5.csv.

New columns added per UE per rate:
  power_{R}M_W        — measured total CPU power during the {R}M test (W)
  power_{R}M_pkg0_W   — pkg-0 only
  power_{R}M_pkg1_W   — pkg-1 only

Derived (scalar, one value per UE — power at each rate):
  power_efficiency_{R}M  — eff_{R}M / power_{R}M_W  (Mbps/W)
  power_slope            — linear slope of power vs rate  (W per 100 Mbps)

All power columns are REAL measurements — not shared node averages.
The old gnb1_*/uehost1_* columns (node-level RAPL averages) are retained as background reference.
"""

import csv, numpy as np, pandas as pd
from pathlib import Path

DATA   = Path("/tmp/ran_data2")
OUTDIR = Path("results")
OUTDIR.mkdir(parents=True, exist_ok=True)
OUT    = OUTDIR / "master_dataset_v5.csv"

RATES = [1, 10, 20, 50, 100, 200, 300, 400, 500]

def flt(v):
    try:
        x = float(v); return x if x == x else np.nan
    except: return np.nan

# ── Load master v4 ────────────────────────────────────────────────────────────
df = pd.read_csv(OUTDIR / "master_dataset_v4.csv")
print(f"master_v4: {df.shape}")

# ── Load per-UE power data ────────────────────────────────────────────────────
power_path = DATA / "per_ue_power.csv"
if not power_path.exists():
    print(f"ERROR: {power_path} not found"); exit(1)

prows = list(csv.DictReader(open(power_path, errors="replace")))
print(f"per_ue_power.csv: {len(prows)} rows")

# Index: uid → rate → {pkg0, pkg1, total, tput, loss, jitter}
power_map = {}
for r in prows:
    uid  = int(flt(r["ue_id"]))
    rate = int(flt(r["rate_mbps"]))
    if uid not in power_map:
        power_map[uid] = {}
    power_map[uid][rate] = {
        "pkg0":  flt(r["ue_pkg0_power_W"]),
        "pkg1":  flt(r["ue_pkg1_power_W"]),
        "total": flt(r["ue_total_cpu_W"]),
        "tput":  flt(r["tput_mbps"]),
        "loss":  flt(r["loss_pct"]),
        "jitter":flt(r["jitter_ms"]),
    }

n_measured = sum(1 for uid in df["ue_id"] if uid in power_map and len(power_map[uid]) == 9)
n_partial  = sum(1 for uid in df["ue_id"] if uid in power_map and 0 < len(power_map[uid]) < 9)
n_missing  = sum(1 for uid in df["ue_id"] if uid not in power_map)
print(f"  Full 9-rate measurements: {n_measured}")
print(f"  Partial: {n_partial}")
print(f"  Missing entirely: {n_missing}")

# ── Add per-rate power columns ─────────────────────────────────────────────────
for rate in RATES:
    col_total = f"power_{rate}M_W"
    col_p0    = f"power_{rate}M_pkg0_W"
    col_p1    = f"power_{rate}M_pkg1_W"
    col_eff   = f"power_eff_{rate}M"

    df[col_total] = df["ue_id"].apply(
        lambda uid: round(power_map.get(int(uid), {}).get(rate, {}).get("total", np.nan), 3))
    df[col_p0] = df["ue_id"].apply(
        lambda uid: round(power_map.get(int(uid), {}).get(rate, {}).get("pkg0", np.nan), 3))
    df[col_p1] = df["ue_id"].apply(
        lambda uid: round(power_map.get(int(uid), {}).get(rate, {}).get("pkg1", np.nan), 3))

    # Power efficiency: effective_tput / power  (Mbps/W)
    eff_col = f"eff_{rate}M"
    df[col_eff] = df.apply(
        lambda row: round(float(row[eff_col]) / float(df.loc[row.name, col_total]), 3)
        if not np.isnan(float(row[eff_col])) and not np.isnan(float(df.loc[row.name, col_total]))
           and float(df.loc[row.name, col_total]) > 0
        else np.nan, axis=1)

# ── Power slope per UE (W per 100 Mbps) ──────────────────────────────────────
def compute_slope(uid):
    """Linear regression slope of total_power vs rate across all 9 rates."""
    pw = power_map.get(int(uid), {})
    pairs = [(r, pw[r]["total"]) for r in RATES
             if r in pw and not np.isnan(pw[r]["total"])]
    if len(pairs) < 3:
        return np.nan
    xs = np.array([p[0] for p in pairs], dtype=float)
    ys = np.array([p[1] for p in pairs], dtype=float)
    slope = np.polyfit(xs, ys, 1)[0]
    return round(slope * 100, 4)   # W per 100 Mbps

df["power_slope_W_per_100Mbps"] = df["ue_id"].apply(compute_slope)

# ── Min / max / range power per UE ───────────────────────────────────────────
def pstat(uid, stat):
    pw = power_map.get(int(uid), {})
    vals = [pw[r]["total"] for r in RATES if r in pw and not np.isnan(pw[r]["total"])]
    if not vals: return np.nan
    if stat == "min":   return round(min(vals), 3)
    if stat == "max":   return round(max(vals), 3)
    if stat == "range": return round(max(vals) - min(vals), 3)
    if stat == "mean":  return round(np.mean(vals), 3)

df["power_min_W"]   = df["ue_id"].apply(lambda u: pstat(u, "min"))
df["power_max_W"]   = df["ue_id"].apply(lambda u: pstat(u, "max"))
df["power_range_W"] = df["ue_id"].apply(lambda u: pstat(u, "range"))
df["power_mean_W"]  = df["ue_id"].apply(lambda u: pstat(u, "mean"))

# ── Summary ───────────────────────────────────────────────────────────────────
new_cols = [c for c in df.columns if c.startswith("power_")]
null_new = df[new_cols].isna().sum().sum()

print(f"\nmaster_dataset_v5:")
print(f"  Shape: {df.shape}")
print(f"  New power columns: {len(new_cols)}")
print(f"  NaN in power cols: {null_new}")
print(f"  Total NaN: {df.isna().sum().sum()}")

print("\n── Per-rate power sample (UE1 – UE5) ──")
show_cols = ["ue_id"] + [f"power_{r}M_W" for r in RATES] + ["power_slope_W_per_100Mbps","power_range_W"]
print(df[show_cols].head(5).to_string())

df.to_csv(OUT, index=False)
print(f"\nSaved → {OUT}  ({OUT.stat().st_size // 1024} KB)")
