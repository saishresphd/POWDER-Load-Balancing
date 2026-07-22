#!/usr/bin/env python3
"""
plot_power_long.py
Plots the 600s power timeseries for gnb1 and uehost1 side by side.
Output: results/plots/power_timeseries_long.png
"""
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
from pathlib import Path

OUT = Path("results/plots/power_timeseries_long.png")
Path("results/plots").mkdir(parents=True, exist_ok=True)

gnb  = pd.read_csv("/tmp/ran_data2/power_gnb1_long.csv")
ue   = pd.read_csv("/tmp/ran_data2/power_uehost1_long.csv")

gnb["total_W"]  = gnb["pkg0_power_W"] + gnb["pkg1_power_W"]
ue["total_W"]   = ue["pkg0_power_W"]  + ue["pkg1_power_W"]

plt.rcParams.update({
    "font.family": "DejaVu Sans", "font.size": 11,
    "axes.titlesize": 12, "axes.labelsize": 11,
    "axes.spines.top": False, "axes.spines.right": False,
    "figure.dpi": 150,
})

fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(12, 4), sharey=False)

# gnb1
ax1.fill_between(gnb["elapsed_s"], gnb["total_W"], alpha=0.15, color="#3b82d4")
ax1.plot(gnb["elapsed_s"], gnb["total_W"],    color="#3b82d4", lw=1.5, label="Total (pkg0+pkg1)")
ax1.plot(gnb["elapsed_s"], gnb["pkg0_power_W"], color="#60a5fa", lw=1.0, ls="--", label="pkg-0")
ax1.plot(gnb["elapsed_s"], gnb["pkg1_power_W"], color="#93c5fd", lw=1.0, ls=":",  label="pkg-1")
ax1.axhline(gnb["total_W"].mean(), color="#3b82d4", lw=0.8, ls="-.", alpha=0.7,
            label=f"mean={gnb['total_W'].mean():.1f} W")
ax1.set_xlabel("Elapsed (s)")
ax1.set_ylabel("Power (W)")
ax1.set_title("gnb1  —  50 srsenb processes")
ax1.legend(fontsize=8, loc="upper right")
ax1.yaxis.set_minor_locator(ticker.AutoMinorLocator())
ax1.set_xlim(0, gnb["elapsed_s"].max())

# uehost1
ax2.fill_between(ue["elapsed_s"], ue["total_W"], alpha=0.15, color="#e07b39")
ax2.plot(ue["elapsed_s"], ue["total_W"],    color="#e07b39", lw=1.5, label="Total (pkg0+pkg1)")
ax2.plot(ue["elapsed_s"], ue["pkg0_power_W"], color="#f97316", lw=1.0, ls="--", label="pkg-0")
ax2.plot(ue["elapsed_s"], ue["pkg1_power_W"], color="#fbbf7a", lw=1.0, ls=":",  label="pkg-1")
ax2.axhline(ue["total_W"].mean(), color="#e07b39", lw=0.8, ls="-.", alpha=0.7,
            label=f"mean={ue['total_W'].mean():.1f} W")
ax2.set_xlabel("Elapsed (s)")
ax2.set_ylabel("Power (W)")
ax2.set_title("uehost1  —  49 srsUE processes")
ax2.legend(fontsize=8, loc="upper right")
ax2.yaxis.set_minor_locator(ticker.AutoMinorLocator())
ax2.set_xlim(0, ue["elapsed_s"].max())

fig.suptitle("RAPL CPU Power — 10-Minute Steady-State Trace", fontsize=13, y=1.01)
fig.tight_layout()
fig.savefig(OUT, bbox_inches="tight", dpi=150)
plt.close(fig)
print(f"Saved: {OUT}")
