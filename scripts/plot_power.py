#!/usr/bin/env python3
"""
plot_power.py
Generates 4 clean power-related plots from master_dataset_v3.csv and power CSVs.
Output: results/plots/power_*.png
"""

import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
from pathlib import Path

OUT_DIR = Path("results/plots")
OUT_DIR.mkdir(parents=True, exist_ok=True)

MASTER = Path("results/master_dataset_v3.csv")
POWER_GNB1   = Path("/tmp/ran_data2/power_gnb1.csv")
POWER_UEHOST = Path("/tmp/ran_data2/power_uehost1.csv")

df = pd.read_csv(MASTER)

# ── Style ─────────────────────────────────────────────────────────────────────
plt.rcParams.update({
    "font.family":   "DejaVu Sans",
    "font.size":     11,
    "axes.titlesize": 13,
    "axes.labelsize": 12,
    "axes.spines.top":   False,
    "axes.spines.right": False,
    "figure.dpi":    150,
})
ACCENT = "#3b82d4"
ORANGE = "#e07b39"

def save(fig, name):
    p = OUT_DIR / name
    fig.savefig(p, bbox_inches="tight", dpi=150)
    plt.close(fig)
    print(f"  Saved: {p}")

# ─────────────────────────────────────────────────────────────────────────────
# Plot 1: Bar chart — power breakdown per node
# ─────────────────────────────────────────────────────────────────────────────
fig, ax = plt.subplots(figsize=(7, 4))
nodes    = ["gnb1\n(50 srsenb)", "uehost1\n(49 srsUE)"]
pkg0     = [df["gnb1_pkg0_power_W"].iloc[0],  df["uehost1_pkg0_power_W"].iloc[0]]
pkg1     = [df["gnb1_pkg1_power_W"].iloc[0],  df["uehost1_pkg1_power_W"].iloc[0]]
dram0    = [df["gnb1_dram0_power_W"].iloc[0], df["uehost1_dram0_power_W"].iloc[0]]
dram1    = [df["gnb1_dram1_power_W"].iloc[0], df["uehost1_dram1_power_W"].iloc[0]]

x    = np.arange(len(nodes))
w    = 0.5
bars = [pkg0, pkg1, dram0, dram1]
labels = ["CPU pkg-0", "CPU pkg-1", "DRAM-0", "DRAM-1"]
colors = ["#3b82d4", "#60a5fa", "#e07b39", "#f7c08a"]

bottom = np.zeros(len(nodes))
for vals, lbl, clr in zip(bars, labels, colors):
    ax.bar(x, vals, w, bottom=bottom, label=lbl, color=clr)
    bottom += np.array(vals)

# annotate totals
for i, tot in enumerate(bottom):
    ax.text(i, tot + 0.4, f"{tot:.1f} W", ha="center", fontsize=10, fontweight="bold")

ax.set_xticks(x)
ax.set_xticklabels(nodes)
ax.set_ylabel("Power (W)")
ax.set_title("RAPL Power Breakdown: gNB vs UE Host")
ax.legend(loc="upper right", fontsize=9)
ax.set_ylim(0, max(bottom) * 1.18)
save(fig, "power_breakdown_bar.png")

# ─────────────────────────────────────────────────────────────────────────────
# Plot 2: Power timeseries (gnb1)
# ─────────────────────────────────────────────────────────────────────────────
if POWER_GNB1.exists():
    pdf = pd.read_csv(POWER_GNB1)
    pdf["total_W"] = pdf["pkg0_power_W"] + pdf["pkg1_power_W"]
    fig, ax = plt.subplots(figsize=(8, 3.5))
    ax.plot(pdf["elapsed_s"], pdf["total_W"],    color=ACCENT,  lw=1.5, label="Total CPU (pkg0+pkg1)")
    ax.plot(pdf["elapsed_s"], pdf["pkg0_power_W"], color="#60a5fa", lw=1,   label="pkg-0", linestyle="--")
    ax.plot(pdf["elapsed_s"], pdf["pkg1_power_W"], color="#93c5fd", lw=1,   label="pkg-1", linestyle=":")
    ax.set_xlabel("Elapsed (s)")
    ax.set_ylabel("Power (W)")
    ax.set_title("gnb1 CPU Power over Time (50 srsenb processes)")
    ax.legend(fontsize=9)
    ax.yaxis.set_minor_locator(ticker.AutoMinorLocator())
    save(fig, "power_timeseries_gnb1.png")

# ─────────────────────────────────────────────────────────────────────────────
# Plot 3: Power timeseries (uehost1)
# ─────────────────────────────────────────────────────────────────────────────
if POWER_UEHOST.exists():
    udf = pd.read_csv(POWER_UEHOST)
    udf["total_W"] = udf["pkg0_power_W"] + udf["pkg1_power_W"]
    fig, ax = plt.subplots(figsize=(8, 3.5))
    ax.plot(udf["elapsed_s"], udf["total_W"],    color=ORANGE,  lw=1.5, label="Total CPU (pkg0+pkg1)")
    ax.plot(udf["elapsed_s"], udf["pkg0_power_W"], color="#e07b39", lw=1,   label="pkg-0", linestyle="--")
    ax.plot(udf["elapsed_s"], udf["pkg1_power_W"], color="#f7c08a", lw=1,   label="pkg-1", linestyle=":")
    ax.set_xlabel("Elapsed (s)")
    ax.set_ylabel("Power (W)")
    ax.set_title("uehost1 CPU Power over Time (49 srsUE processes)")
    ax.legend(fontsize=9)
    ax.yaxis.set_minor_locator(ticker.AutoMinorLocator())
    save(fig, "power_timeseries_uehost1.png")

# ─────────────────────────────────────────────────────────────────────────────
# Plot 4: Energy efficiency — effective throughput vs power per UE
# ─────────────────────────────────────────────────────────────────────────────
RATES = [1, 10, 20, 50, 100, 200, 300, 400, 500]
# power_per_ue is fixed across UEs (node-level) — use uehost1 total
power_per_ue_W = float(df["uehost1_power_per_ue_W"].iloc[0])

# median effective throughput per rate across all UEs
eff_medians = []
for r in RATES:
    col = f"eff_{r}M"
    if col in df.columns:
        vals = df[col].dropna()
        eff_medians.append(float(vals.median()) if len(vals) else 0)
    else:
        eff_medians.append(0)

# efficiency = effective_tput_Mbps / power_W → Mbps/W
efficiency = [e / power_per_ue_W if power_per_ue_W > 0 else 0 for e in eff_medians]

fig, ax = plt.subplots(figsize=(8, 4))
x = np.arange(len(RATES))
ax.bar(x, efficiency, color=ACCENT)
ax.set_xticks(x)
ax.set_xticklabels([f"{r}M" for r in RATES])
ax.set_xlabel("Target UDP Rate")
ax.set_ylabel("Efficiency (Mbps / W)")
ax.set_title(f"Energy Efficiency per UE  (power={power_per_ue_W:.2f} W/UE on uehost1)")
for i, v in enumerate(efficiency):
    ax.text(i, v + 0.001, f"{v:.2f}", ha="center", fontsize=8)
save(fig, "power_efficiency_per_ue.png")

print("\nAll power plots saved to results/plots/")
