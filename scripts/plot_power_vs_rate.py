#!/usr/bin/env python3
"""
plot_power_vs_rate.py
─────────────────────
Plots per-UE power measurement results from master_dataset_v5.csv.
4 plots:
  1. power vs rate (line per UE, 49 lines — shows variation)
  2. mean power ± std per rate (bar chart)
  3. power range per UE (bar — how much each UE varies with load)
  4. power efficiency (Mbps/W) vs rate
"""
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.cm as cm
from pathlib import Path

MASTER = Path("results/master_dataset_v5.csv")
OUT_DIR = Path("results/plots")
OUT_DIR.mkdir(parents=True, exist_ok=True)

df = pd.read_csv(MASTER)
RATES = [1, 10, 20, 50, 100, 200, 300, 400, 500]

plt.rcParams.update({
    "font.family": "DejaVu Sans", "font.size": 11,
    "axes.titlesize": 12, "axes.labelsize": 11,
    "axes.spines.top": False, "axes.spines.right": False,
    "figure.dpi": 150,
})

def save(fig, name):
    p = OUT_DIR / name
    fig.savefig(p, bbox_inches="tight", dpi=150)
    plt.close(fig)
    print(f"  Saved: {p}")

# ── Plot 1: Power vs rate — one line per UE ───────────────────────────────────
fig, ax = plt.subplots(figsize=(10, 5))
cmap = plt.colormaps["tab20"].resampled(len(df))
for i, row in df.iterrows():
    uid = int(row["ue_id"])
    ys = [row.get(f"power_{r}M_W", np.nan) for r in RATES]
    if all(np.isnan(y) for y in ys): continue
    ax.plot(RATES, ys, alpha=0.55, lw=1.2, color=cmap(i))

ax.set_xscale("log")
ax.set_xticks(RATES)
ax.set_xticklabels([f"{r}M" for r in RATES], fontsize=9)
ax.set_xlabel("UDP Target Rate (Mbps)")
ax.set_ylabel("Total CPU Power (W)\n[pkg0 + pkg1, uehost1]")
ax.set_title("Per-UE Power vs Throughput Rate  (49 UEs)")
sm = plt.cm.ScalarMappable(cmap=plt.colormaps["tab20"], norm=plt.Normalize(1, 49))
sm.set_array([])
plt.colorbar(sm, ax=ax, label="UE ID", shrink=0.85)
save(fig, "power_per_ue_vs_rate.png")

# ── Plot 2: Mean ± std power per rate ────────────────────────────────────────
means, stds = [], []
for r in RATES:
    col = f"power_{r}M_W"
    vals = df[col].dropna()
    means.append(float(vals.mean()) if len(vals) else 0)
    stds.append(float(vals.std())  if len(vals) else 0)

fig, ax = plt.subplots(figsize=(8, 4))
x = np.arange(len(RATES))
bars = ax.bar(x, means, color="#3b82d4", yerr=stds, capsize=4, error_kw={"lw": 1.2})
ax.set_xticks(x)
ax.set_xticklabels([f"{r}M" for r in RATES])
ax.set_xlabel("UDP Target Rate")
ax.set_ylabel("Mean Total CPU Power (W)")
ax.set_title("Mean Power per Rate  (49 UEs, error bar = ±1 std)")
ax.set_ylim(0, max(m + s for m, s in zip(means, stds)) * 1.15)
for i, (m, s) in enumerate(zip(means, stds)):
    ax.text(i, m + s + 0.3, f"{m:.1f}W", ha="center", fontsize=8)
save(fig, "power_mean_per_rate.png")

# ── Plot 3: Power range per UE (max - min across all rates) ──────────────────
df_sorted = df.sort_values("power_range_W", ascending=False).reset_index(drop=True)

fig, ax = plt.subplots(figsize=(12, 4))
ax.bar(df_sorted["ue_id"].astype(str), df_sorted["power_range_W"],
       color="#e07b39", alpha=0.85)
ax.set_xlabel("UE ID")
ax.set_ylabel("Power Range (W)  [max - min across 9 rates]")
ax.set_title("Per-UE Power Variation with Load")
ax.tick_params(axis="x", labelsize=7, rotation=90)
save(fig, "power_range_per_ue.png")

# ── Plot 4: Power efficiency (Mbps/W) per rate ─────────────────────────────────
eff_means, eff_stds = [], []
for r in RATES:
    col = f"power_eff_{r}M"
    if col in df.columns:
        vals = df[col].dropna()
        eff_means.append(float(vals.mean()) if len(vals) else 0)
        eff_stds.append(float(vals.std())  if len(vals) else 0)
    else:
        eff_means.append(0); eff_stds.append(0)

fig, ax = plt.subplots(figsize=(8, 4))
x = np.arange(len(RATES))
ax.bar(x, eff_means, color="#7c5cd8", yerr=eff_stds, capsize=4,
       error_kw={"lw": 1.2}, alpha=0.85)
ax.set_xticks(x)
ax.set_xticklabels([f"{r}M" for r in RATES])
ax.set_xlabel("UDP Target Rate")
ax.set_ylabel("Energy Efficiency (Mbps / W)")
ax.set_title("Power Efficiency per Rate  (effective throughput / total CPU power)")
for i, v in enumerate(eff_means):
    ax.text(i, v + max(eff_stds) * 0.1 + 0.001, f"{v:.2f}", ha="center", fontsize=8)
save(fig, "power_efficiency_per_rate.png")

print("\nAll power-vs-rate plots saved to results/plots/")
