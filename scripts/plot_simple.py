#!/usr/bin/env python3
"""
plot_simple.py  —  Clean, non-overlapping bar/line/box plots for all 50 UEs.
One metric per figure.  No dual axes.  All labels readable.
"""

import csv, os, warnings
from pathlib import Path
from collections import defaultdict

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import numpy as np

warnings.filterwarnings("ignore")

# ── Paths ─────────────────────────────────────────────────────────────────────
DATA   = Path("/tmp/ran_data2")
OUTDIR = Path(os.path.expanduser("~/Desktop/plots"))
OUTDIR.mkdir(parents=True, exist_ok=True)

# ── Style ─────────────────────────────────────────────────────────────────────
plt.rcParams.update({
    "figure.facecolor": "#ffffff",
    "axes.facecolor":   "#f9fafb",
    "axes.edgecolor":   "#cccccc",
    "axes.grid":        True,
    "grid.color":       "#e5e7eb",
    "grid.linewidth":   0.6,
    "font.family":      "DejaVu Sans",
    "font.size":        10,
    "axes.titlesize":   12,
    "axes.titleweight": "bold",
    "axes.labelsize":   10,
    "xtick.labelsize":  8,
    "ytick.labelsize":  9,
    "legend.fontsize":  9,
    "lines.linewidth":  1.8,
    "lines.markersize": 5,
})

BLUE   = "#3b82d4"
GREEN  = "#22c55e"
ORANGE = "#f97316"
RED    = "#ef4444"
PURPLE = "#7c3aed"
GREY   = "#9ca3af"

ALL_UES = list(range(1, 51))
UE_LABELS = [f"UE{i}" for i in ALL_UES]

def flt(v, default=None):
    try:
        x = float(v)
        return None if x != x else x
    except: return default

def load(name):
    p = DATA / name
    return list(csv.DictReader(open(p, errors="replace"))) if p.exists() else []

def save(fig, name, subdir=""):
    d = OUTDIR / subdir if subdir else OUTDIR
    d.mkdir(parents=True, exist_ok=True)
    path = d / name
    fig.savefig(path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  ✓ {path.name}")

# ── Load data ─────────────────────────────────────────────────────────────────
print("Loading …")
udp_rows = load("udp_latency_all_ues.csv")
gnb_rich = load("gnb1_rich_metrics.csv")
ue_phy   = load("ue_phy_metrics.csv")
deep_gnb = load("deep_gnb1.csv")
deep_ue  = load("deep_uehost1.csv")

# ── Build per-UE UDP lookup ───────────────────────────────────────────────────
RATES = [1, 10, 20, 50, 100, 200, 300, 400, 500]
ue_tput = defaultdict(dict)
ue_jit  = defaultdict(dict)
ue_loss = defaultdict(dict)
ue_ping_base = {}
ue_ping_load = {}

for r in udp_rows:
    uid   = int(r["ue_id"])
    ttype = r["test_type"]
    if ttype in ("udp_ramp", "udp_ramp_retest"):
        rate = int(float(r["rate_target_mbps"]))
        tp   = flt(r["throughput_mbps"])
        jt   = flt(r["jitter_ms"])
        ls   = flt(r["pkt_loss_pct"])
        if tp and tp > 0:
            ue_tput[uid][rate] = tp
            ue_jit[uid][rate]  = jt or 0
            ue_loss[uid][rate] = ls or 0
    elif ttype in ("ping_baseline", "ping_baseline_retest"):
        ue_ping_base[uid] = {k: flt(r[k]) for k in
                             ["ping_min_ms","ping_avg_ms","ping_max_ms","ping_mdev_ms","ping_loss_pct"]}
    elif ttype in ("ping_under_load","ping_under_load_retest"):
        ue_ping_load[uid] = {k: flt(r[k]) for k in
                             ["ping_avg_ms","ping_mdev_ms","ping_loss_pct"]}

# per-UE RAN lookup
gnb_by_ue = {int(r["ue_id"]): r for r in gnb_rich}

def gval(uid, key):
    return flt(gnb_by_ue.get(uid, {}).get(key, "NA"))

# ue_phy (column shift: rss_kB=pid, vsz_kB=rss, threads=vsz)
pid_to_uid = {}
for r in ue_phy:
    uid = int(r["ue_id"])
    pid = flt(r.get("rss_kB","NA"))
    if pid: pid_to_uid[int(pid)] = uid

ue_proc = defaultdict(lambda: defaultdict(list))
for r in deep_ue:
    pid = flt(r.get("proc_pid","NA"))
    if not pid: continue
    uid = pid_to_uid.get(int(pid))
    if not uid: continue
    for k in ["proc_rss_kB","proc_vsz_kB","proc_cpu_total_pct",
              "proc_vol_ctxsw_s","proc_nonvol_ctxsw_s","proc_schedwait_ns"]:
        v = flt(r.get(k,"NA"))
        if v is not None and v >= 0:
            ue_proc[uid][k].append(v)

def pmean(uid, key):
    v = ue_proc[uid].get(key, [])
    return sum(v)/len(v) if v else None

# ══════════════════════════════════════════════════════════════════════════════
#  SECTION A: UDP THROUGHPUT
# ══════════════════════════════════════════════════════════════════════════════
print("\n── Section A: UDP Throughput ──")

# A1: Throughput at 100 Mbps — horizontal bar, all 49 UEs sorted
print("A1: throughput @ 100M …")
tput_100 = [(uid, ue_tput[uid].get(100, 0) or 0) for uid in range(1,51) if uid != 40]
tput_100.sort(key=lambda x: x[1], reverse=True)
ues_s, vals_s = zip(*tput_100)

fig, ax = plt.subplots(figsize=(10, 14))
colors = [BLUE if v > 0 else RED for v in vals_s]
bars = ax.barh([f"UE{u}" for u in ues_s], vals_s, color=colors, edgecolor="white", height=0.7)
ax.set_xlabel("Actual Throughput (Mbps)")
ax.set_title("UDP Throughput @ 100 Mbps Target — All 49 UEs (sorted)")
ax.axvline(x=99.9, color=ORANGE, ls="--", lw=1.4, label="Target 100 Mbps")
for bar, val in zip(bars, vals_s):
    if val > 0:
        ax.text(val + 0.5, bar.get_y() + bar.get_height()/2,
                f"{val:.1f}", va="center", fontsize=6.5, color="#333")
ax.legend()
fig.tight_layout()
save(fig, "A1_tput_100M_all_ues.png")

# A2: Mean throughput across all rates — bar chart
print("A2: mean throughput all UEs all rates …")
mean_tputs = []
for uid in range(1, 51):
    if uid == 40: continue
    vals = [v for v in ue_tput[uid].values() if v and v > 0]
    mean_tputs.append((uid, sum(vals)/len(vals) if vals else 0, len(vals)))

mean_tputs.sort(key=lambda x: x[0])  # sort by UE ID
ues_ids = [x[0] for x in mean_tputs]
means   = [x[1] for x in mean_tputs]
n_rates = [x[2] for x in mean_tputs]
colors  = [BLUE if n >= 7 else (ORANGE if n >= 2 else RED) for n in n_rates]

fig, ax = plt.subplots(figsize=(18, 5))
x = np.arange(len(ues_ids))
ax.bar(x, means, color=colors, edgecolor="white", width=0.75)
ax.set_xticks(x)
ax.set_xticklabels([f"UE{u}" for u in ues_ids], rotation=45, ha="right", fontsize=7.5)
ax.set_ylabel("Mean Throughput (Mbps)")
ax.set_title("Mean UDP Throughput Across All Tested Rates — All 49 UEs")
patches = [mpatches.Patch(color=BLUE, label="≥7 rates tested"),
           mpatches.Patch(color=ORANGE, label="2–6 rates tested"),
           mpatches.Patch(color=RED, label="0–1 rate tested")]
ax.legend(handles=patches)
fig.tight_layout()
save(fig, "A2_mean_tput_all_ues.png")

# A3: Throughput ramp — line plot one line per UE, clean
print("A3: throughput ramp all valid UEs …")
valid_ues = [uid for uid in range(1,51) if uid!=40 and len(ue_tput[uid]) >= 7]
fig, ax = plt.subplots(figsize=(12, 6))
cmap = plt.cm.tab20(np.linspace(0, 1, len(valid_ues)))
for ci, uid in enumerate(valid_ues):
    y = [ue_tput[uid].get(r, np.nan) for r in RATES]
    ax.plot(RATES, y, color=cmap[ci], marker="o", ms=3.5, lw=1.4, label=f"UE{uid}")
ax.set_xlabel("Target UDP Rate (Mbps)")
ax.set_ylabel("Actual Throughput (Mbps)")
ax.set_title(f"UDP Throughput Ramp — {len(valid_ues)} UEs with Complete Data")
ax.set_xscale("log")
ax.set_xticks(RATES)
ax.get_xaxis().set_major_formatter(matplotlib.ticker.ScalarFormatter())
ax.legend(ncol=5, fontsize=7, loc="upper left", framealpha=0.8)
fig.tight_layout()
save(fig, "A3_tput_ramp_valid_ues.png")

# A4: Box plot — distribution of throughput at each rate
print("A4: box plot tput distribution per rate …")
box_data = []
for rate in RATES:
    vals = [ue_tput[uid].get(rate) for uid in range(1,51)
            if uid != 40 and ue_tput[uid].get(rate) and ue_tput[uid].get(rate) > 0]
    box_data.append(vals)

fig, ax = plt.subplots(figsize=(12, 5))
bp = ax.boxplot(box_data, patch_artist=True, notch=False,
                tick_labels=[f"{r}M" for r in RATES], widths=0.5)
for patch in bp["boxes"]:
    patch.set_facecolor(BLUE); patch.set_alpha(0.6)
for w in bp["whiskers"]: w.set_color("#555")
for c in bp["caps"]:     c.set_color("#555")
for m in bp["medians"]:  m.set_color(ORANGE); m.set_linewidth(2)
for f in bp["fliers"]:   f.set(marker="o", markersize=4, color=RED, alpha=0.5)
ax.set_xlabel("Target UDP Rate")
ax.set_ylabel("Actual Throughput (Mbps)")
ax.set_title("Distribution of UDP Throughput at Each Rate (all UEs)")
for i, vals in enumerate(box_data):
    ax.text(i+1, ax.get_ylim()[0]-ax.get_ylim()[0]*0.04,
            f"n={len(vals)}", ha="center", fontsize=7.5, color="#555")
fig.tight_layout()
save(fig, "A4_tput_boxplot_per_rate.png")

# A5: Jitter — bar chart at 100M for all UEs
print("A5: jitter @ 100M …")
jit_100 = [(uid, ue_jit[uid].get(100, 0) or 0) for uid in range(1,51) if uid != 40]
jit_100.sort(key=lambda x: x[0])
fig, ax = plt.subplots(figsize=(18, 4))
x = np.arange(len(jit_100))
vals = [v for _,v in jit_100]
ax.bar(x, vals, color=PURPLE, edgecolor="white", width=0.75)
ax.set_xticks(x)
ax.set_xticklabels([f"UE{u}" for u,_ in jit_100], rotation=45, ha="right", fontsize=7.5)
ax.set_ylabel("Jitter (ms)")
ax.set_title("UDP Jitter @ 100 Mbps — All 49 UEs")
fig.tight_layout()
save(fig, "A5_jitter_100M_all_ues.png")

# A6: Box plot — jitter distribution per rate
print("A6: box plot jitter per rate …")
box_jit = []
for rate in RATES:
    vals = [ue_jit[uid].get(rate) for uid in range(1,51)
            if uid != 40 and ue_jit[uid].get(rate) and ue_tput[uid].get(rate, 0) > 0]
    box_jit.append([v for v in vals if v is not None])

fig, ax = plt.subplots(figsize=(12, 5))
bp = ax.boxplot(box_jit, patch_artist=True,
                tick_labels=[f"{r}M" for r in RATES], widths=0.5)
for patch in bp["boxes"]:
    patch.set_facecolor(PURPLE); patch.set_alpha(0.6)
for m in bp["medians"]: m.set_color(ORANGE); m.set_linewidth(2)
for f in bp["fliers"]:  f.set(marker="o", markersize=4, color=RED, alpha=0.5)
ax.set_xlabel("Target UDP Rate")
ax.set_ylabel("Jitter (ms)")
ax.set_title("Distribution of UDP Jitter at Each Rate (all UEs)")
fig.tight_layout()
save(fig, "A6_jitter_boxplot_per_rate.png")

# ══════════════════════════════════════════════════════════════════════════════
#  SECTION B: ICMP LATENCY
# ══════════════════════════════════════════════════════════════════════════════
print("\n── Section B: ICMP Latency ──")

# B1: Bar — avg RTT all UEs (baseline idle)
print("B1: avg RTT baseline …")
ping_ues = sorted(ue_ping_base.keys())
fig, ax = plt.subplots(figsize=(18, 5))
x = np.arange(len(ping_ues))
avgs  = [ue_ping_base[u]["ping_avg_ms"]  or 0 for u in ping_ues]
mins_ = [ue_ping_base[u]["ping_min_ms"]  or 0 for u in ping_ues]
maxs  = [ue_ping_base[u]["ping_max_ms"]  or 0 for u in ping_ues]
mdevs = [ue_ping_base[u]["ping_mdev_ms"] or 0 for u in ping_ues]

ax.bar(x, avgs, color=BLUE, edgecolor="white", width=0.7, label="Avg RTT")
ax.errorbar(x, avgs, yerr=mdevs, fmt="none", ecolor=ORANGE, capsize=3, lw=1.2, label="±jitter (mdev)")
ax.set_xticks(x)
ax.set_xticklabels([f"UE{u}" for u in ping_ues], rotation=45, ha="right", fontsize=7.5)
ax.set_ylabel("RTT (ms)")
ax.set_title("ICMP Latency (Baseline Idle) — 49 UEs\n  Bars=Avg RTT, Error bars=Jitter (mdev)")
ax.legend()
fig.tight_layout()
save(fig, "B1_latency_avg_all_ues.png")

# B2: Box plot — latency distribution across all UEs
print("B2: latency box plot …")
fig, ax = plt.subplots(figsize=(8, 6))
box_vals = [avgs, mins_, maxs, mdevs]
labels   = ["Avg RTT", "Min RTT", "Max RTT", "Jitter\n(mdev)"]
colors_b = [BLUE, GREEN, RED, ORANGE]
bp = ax.boxplot(box_vals, patch_artist=True, tick_labels=labels, widths=0.5)
for patch, c in zip(bp["boxes"], colors_b):
    patch.set_facecolor(c); patch.set_alpha(0.65)
for m in bp["medians"]: m.set_color("white"); m.set_linewidth(2)
for f in bp["fliers"]:  f.set(marker="o", markersize=5, alpha=0.5)
ax.set_ylabel("RTT (ms)")
ax.set_title("Latency Distribution Across 49 UEs\n(ICMP Ping to Core, 20 pings each)")
fig.tight_layout()
save(fig, "B2_latency_distribution.png")

# B3: Idle vs under-load comparison bar
print("B3: idle vs load latency …")
common = sorted(set(ue_ping_base) & set(ue_ping_load))
idle_avgs = [ue_ping_base[u]["ping_avg_ms"] or 0 for u in common]
load_avgs = [ue_ping_load[u]["ping_avg_ms"] or 0 for u in common]
x = np.arange(len(common))
w = 0.38

fig, ax = plt.subplots(figsize=(18, 5))
ax.bar(x - w/2, idle_avgs, width=w, color=BLUE,   edgecolor="white", label="Idle (baseline)")
ax.bar(x + w/2, load_avgs, width=w, color=ORANGE,  edgecolor="white", label="Under 100 Mbps load")
ax.set_xticks(x)
ax.set_xticklabels([f"UE{u}" for u in common], rotation=45, ha="right", fontsize=7.5)
ax.set_ylabel("Avg RTT (ms)")
ax.set_title("ICMP Latency: Idle vs Under 100 Mbps UDP Load — 49 UEs")
ax.legend()
fig.tight_layout()
save(fig, "B3_latency_idle_vs_load.png")

# ══════════════════════════════════════════════════════════════════════════════
#  SECTION C: RAN RADIO METRICS
# ══════════════════════════════════════════════════════════════════════════════
print("\n── Section C: RAN Metrics ──")

ran_ues = list(range(1, 51))

# C1: Bar — PUCCH SNR all 50 UEs
print("C1: PUCCH SNR …")
snr_vals = [gval(u, "pucch_snr_db") or 0 for u in ran_ues]
fig, ax = plt.subplots(figsize=(18, 4))
x = np.arange(50)
colors = [BLUE if v > 0 else GREY for v in snr_vals]
ax.bar(x, snr_vals, color=colors, edgecolor="white", width=0.75)
ax.set_xticks(x)
ax.set_xticklabels([f"UE{u}" for u in ran_ues], rotation=45, ha="right", fontsize=7.5)
ax.set_ylabel("PUCCH SNR (dB)")
ax.set_title("PUCCH SNR per UE — 50 UE Slots (gnb1 logs)")
ax.set_ylim(0, 130)
fig.tight_layout()
save(fig, "C1_pucch_snr_all_ues.png")

# C2: Bar — CQI all 50 UEs
print("C2: CQI …")
cqi_vals = [gval(u, "pucch_cqi") or 0 for u in ran_ues]
fig, ax = plt.subplots(figsize=(18, 4))
ax.bar(x, cqi_vals, color=GREEN, edgecolor="white", width=0.75)
ax.set_xticks(x)
ax.set_xticklabels([f"UE{u}" for u in ran_ues], rotation=45, ha="right", fontsize=7.5)
ax.set_ylabel("CQI (0–15)")
ax.set_title("Channel Quality Indicator (CQI) per UE — 50 UE Slots")
ax.set_ylim(0, 16)
ax.axhline(y=15, color=ORANGE, ls="--", lw=1.2, label="Max CQI = 15")
ax.legend()
fig.tight_layout()
save(fig, "C2_cqi_all_ues.png")

# C3: Bar — PRB utilization all 50 UEs
print("C3: PRB utilization …")
prb_util = [gval(u, "prb_util_pct") or 0 for u in ran_ues]
prb_abs  = [gval(u, "pdsch_nof_prb") or 0 for u in ran_ues]
fig, ax = plt.subplots(figsize=(18, 4))
ax.bar(x, prb_util, color=PURPLE, edgecolor="white", width=0.75)
ax.set_xticks(x)
ax.set_xticklabels([f"UE{u}" for u in ran_ues], rotation=45, ha="right", fontsize=7.5)
ax.set_ylabel("PRB Utilization (%)")
ax.set_title("DL PRB Utilization per UE Slot (PDSCH, 50 total PRBs)")
ax.set_ylim(0, 100)
for xi, (util, prb) in enumerate(zip(prb_util, prb_abs)):
    if util > 0:
        ax.text(xi, util + 0.5, f"{int(prb)}", ha="center", fontsize=5.5, color="#444")
fig.tight_layout()
save(fig, "C3_prb_utilization_all_ues.png")

# C4: Grouped bar — UL MCS vs DL MCS
print("C4: MCS UL vs DL …")
mcs_ul = [gval(u, "pusch_mcs") or 0 for u in ran_ues]
mcs_dl = [gval(u, "pdsch_mcs") or 0 for u in ran_ues]
w = 0.38
fig, ax = plt.subplots(figsize=(18, 4))
ax.bar(x - w/2, mcs_ul, width=w, color=BLUE,   edgecolor="white", label="UL MCS (PUSCH)")
ax.bar(x + w/2, mcs_dl, width=w, color=ORANGE, edgecolor="white", label="DL MCS (PDSCH)")
ax.set_xticks(x)
ax.set_xticklabels([f"UE{u}" for u in ran_ues], rotation=45, ha="right", fontsize=7.5)
ax.set_ylabel("MCS")
ax.set_title("Modulation & Coding Scheme (MCS) — UL vs DL — 50 UE Slots")
ax.legend()
fig.tight_layout()
save(fig, "C4_mcs_ul_dl_all_ues.png")

# C5: Bar — PUSCH SNR
print("C5: PUSCH SNR …")
snr_ul = [gval(u, "pusch_snr_db") or 0 for u in ran_ues]
fig, ax = plt.subplots(figsize=(18, 4))
colors = [BLUE if v > 0 else GREY for v in snr_ul]
ax.bar(x, snr_ul, color=colors, edgecolor="white", width=0.75)
ax.set_xticks(x)
ax.set_xticklabels([f"UE{u}" for u in ran_ues], rotation=45, ha="right", fontsize=7.5)
ax.set_ylabel("PUSCH SNR (dB)")
ax.set_title("PUSCH UL SNR per UE Slot — 50 UE Slots")
ax.set_ylim(0, 130)
fig.tight_layout()
save(fig, "C5_pusch_snr_all_ues.png")

# C6: Box plot — RAN metrics distribution
print("C6: RAN box plots …")
ran_metrics = {
    "PUCCH SNR (dB)": [gval(u,"pucch_snr_db") for u in ran_ues],
    "PUSCH SNR (dB)": [gval(u,"pusch_snr_db") for u in ran_ues],
    "CQI":            [gval(u,"pucch_cqi")     for u in ran_ues],
    "DL PRB count":   [gval(u,"pdsch_nof_prb") for u in ran_ues],
    "UL MCS":         [gval(u,"pusch_mcs")     for u in ran_ues],
    "DL MCS":         [gval(u,"pdsch_mcs")     for u in ran_ues],
}
fig, axes = plt.subplots(2, 3, figsize=(14, 8))
fig.suptitle("RAN Metric Distributions — 50 UE Slots (box plots)", fontsize=12, fontweight="bold")
pal = [BLUE, GREEN, ORANGE, PURPLE, RED, "#06b6d4"]
for (label, vals), ax, c in zip(ran_metrics.items(), axes.flat, pal):
    clean = [v for v in vals if v is not None and v > 0]
    if clean:
        bp = ax.boxplot(clean, patch_artist=True, widths=0.5)
        bp["boxes"][0].set_facecolor(c); bp["boxes"][0].set_alpha(0.6)
        bp["medians"][0].set_color("black"); bp["medians"][0].set_linewidth(2)
        for f in bp["fliers"]: f.set(marker="o", markersize=4, alpha=0.5)
    ax.set_title(label, fontsize=10)
    ax.set_ylabel(label)
    ax.set_xticks([])
    mn = min(clean) if clean else 0
    mx = max(clean) if clean else 0
    med = sorted(clean)[len(clean)//2] if clean else 0
    ax.text(1.35, med, f"median={med:.1f}\nn={len(clean)}", va="center",
            fontsize=8.5, color="#333", transform=ax.transData)
fig.tight_layout()
save(fig, "C6_ran_metrics_boxplots.png")

# ══════════════════════════════════════════════════════════════════════════════
#  SECTION D: CPU & MEMORY
# ══════════════════════════════════════════════════════════════════════════════
print("\n── Section D: CPU & Memory ──")

# D1: Bar — srsenb CPU max per UE slot from gnb1_rich
print("D1: srsenb CPU per slot …")
cpu_max  = [gval(u,"cpu_max")  or 0 for u in ran_ues]
cpu_mean = [gval(u,"cpu_mean") or 0 for u in ran_ues]
rss_mb   = [(gval(u,"proc_rss_kB") or 0)/1024 for u in ran_ues]

fig, ax = plt.subplots(figsize=(18, 5))
w = 0.38
colors_valid = [BLUE if cpu_max[i] > 0 else GREY for i in range(50)]
ax.bar(x - w/2, cpu_max,  width=w, color=BLUE,   edgecolor="white", label="CPU Max %")
ax.bar(x + w/2, cpu_mean, width=w, color=GREEN,  edgecolor="white", label="CPU Mean %")
ax.set_xticks(x)
ax.set_xticklabels([f"UE{u}" for u in ran_ues], rotation=45, ha="right", fontsize=7.5)
ax.set_ylabel("CPU %")
ax.set_title("srsenb Per-Slot CPU Usage — 50 UE Slots (gnb1)")
ax.legend()
fig.tight_layout()
save(fig, "D1_srsenb_cpu_per_slot.png")

# D2: Bar — srsenb RSS per UE slot
print("D2: srsenb RSS per slot …")
fig, ax = plt.subplots(figsize=(18, 4))
colors = [BLUE if v > 0 else GREY for v in rss_mb]
ax.bar(x, rss_mb, color=colors, edgecolor="white", width=0.75)
ax.set_xticks(x)
ax.set_xticklabels([f"UE{u}" for u in ran_ues], rotation=45, ha="right", fontsize=7.5)
ax.set_ylabel("Process RSS (MB)")
ax.set_title("srsenb Process RSS (Physical RAM) per Slot — 50 UE Slots")
ax.axhline(y=800, color=ORANGE, ls="--", lw=1, label="800 MB reference")
ax.legend()
fig.tight_layout()
save(fig, "D2_srsenb_rss_per_slot.png")

# D3: srsue CPU per UE (from deep_uehost1)
print("D3: srsue CPU per UE …")
ue_cpu = [(uid, pmean(uid,"proc_cpu_total_pct") or 0) for uid in range(1,51) if uid != 40]
ue_cpu.sort(key=lambda x: x[0])
ue_ids_c = [u for u,_ in ue_cpu]
cpu_vals  = [v for _,v in ue_cpu]
colors = [BLUE if v > 0 else GREY for v in cpu_vals]

fig, ax = plt.subplots(figsize=(18, 4))
x2 = np.arange(len(ue_ids_c))
ax.bar(x2, cpu_vals, color=colors, edgecolor="white", width=0.75)
ax.set_xticks(x2)
ax.set_xticklabels([f"UE{u}" for u in ue_ids_c], rotation=45, ha="right", fontsize=7.5)
ax.set_ylabel("CPU Total %")
ax.set_title("srsue Process CPU Usage per UE (mean over collection period)")
fig.tight_layout()
save(fig, "D3_srsue_cpu_per_ue.png")

# D4: srsue RSS per UE
print("D4: srsue RSS per UE …")
ue_rss = [(uid, (pmean(uid,"proc_rss_kB") or 0)/1024) for uid in range(1,51) if uid != 40]
ue_rss.sort(key=lambda x: x[0])
rss_vals = [v for _,v in ue_rss]
colors = [GREEN if v > 0 else GREY for v in rss_vals]

fig, ax = plt.subplots(figsize=(18, 4))
ax.bar(x2, rss_vals, color=colors, edgecolor="white", width=0.75)
ax.set_xticks(x2)
ax.set_xticklabels([f"UE{u}" for u in ue_ids_c], rotation=45, ha="right", fontsize=7.5)
ax.set_ylabel("Process RSS (MB)")
ax.set_title("srsue Process RSS (Physical RAM) per UE (mean)")
fig.tight_layout()
save(fig, "D4_srsue_rss_per_ue.png")

# D5: Box plot — CPU and RSS distribution
print("D5: CPU/RSS box plots …")
fig, axes = plt.subplots(1, 4, figsize=(16, 5))
fig.suptitle("CPU & Memory Distribution Across All UEs", fontsize=12, fontweight="bold")

datasets = [
    ("srsenb CPU Max %",    [gval(u,"cpu_max")  for u in ran_ues], BLUE),
    ("srsenb RSS (MB)",     [rss_mb[i] for i in range(50)], GREEN),
    ("srsue CPU Total %",   [pmean(uid,"proc_cpu_total_pct") for uid in range(1,51) if uid!=40], ORANGE),
    ("srsue RSS (MB)",      [(pmean(uid,"proc_rss_kB") or 0)/1024 for uid in range(1,51) if uid!=40], PURPLE),
]
for (label, vals, c), ax in zip(datasets, axes):
    clean = [v for v in vals if v is not None and v > 0]
    bp = ax.boxplot(clean, patch_artist=True, widths=0.5)
    bp["boxes"][0].set_facecolor(c); bp["boxes"][0].set_alpha(0.65)
    bp["medians"][0].set_color("black"); bp["medians"][0].set_linewidth(2.5)
    for f in bp["fliers"]: f.set(marker="o", markersize=4, alpha=0.5)
    ax.set_title(label, fontsize=9.5)
    ax.set_xticks([]); ax.set_ylabel(label.split("(")[1].rstrip(")") if "(" in label else "")
    med = sorted(clean)[len(clean)//2] if clean else 0
    ax.text(1.02, 0.97, f"median\n{med:.1f}", transform=ax.transAxes,
            fontsize=8, va="top", color="#333")

fig.tight_layout()
save(fig, "D5_cpu_rss_boxplots.png")

# ══════════════════════════════════════════════════════════════════════════════
#  SECTION E: TIMESERIES (gnb1 node)
# ══════════════════════════════════════════════════════════════════════════════
print("\n── Section E: Timeseries ──")

def ts(key, clip_top=None):
    vals = []
    for r in deep_gnb:
        v = flt(r.get(key,"NA"))
        if v is not None:
            if clip_top and v > clip_top: continue
            vals.append(v)
    return vals

t_samples = list(range(len(ts("node_cpu_user_pct"))))
t_sec = [i*5 for i in t_samples]

def ts_fig(key, ylabel, title, color, fname, clip_top=None):
    vals = ts(key, clip_top)
    t = [i*5 for i in range(len(vals))]
    fig, ax = plt.subplots(figsize=(14, 4))
    ax.plot(t, vals, color=color, lw=1.6)
    ax.fill_between(t, vals, alpha=0.15, color=color)
    ax.set_xlabel("Time (seconds)")
    ax.set_ylabel(ylabel)
    ax.set_title(title)
    if vals:
        ax.axhline(sum(vals)/len(vals), color="#999", ls="--", lw=1,
                   label=f"Mean = {sum(vals)/len(vals):.1f}")
        ax.legend(fontsize=9)
    fig.tight_layout()
    save(fig, fname)

print("E1: CPU user …")
ts_fig("node_cpu_user_pct",   "CPU User %",   "gnb1 CPU User % over Time (50 srsenb running)",          BLUE,   "E1_gnb1_cpu_user_timeseries.png")
print("E2: CPU sys …")
ts_fig("node_cpu_sys_pct",    "CPU Sys %",    "gnb1 CPU Kernel/Sys % over Time",                        ORANGE, "E2_gnb1_cpu_sys_timeseries.png")
print("E3: temp pkg0 …")
ts_fig("node_temp_package0_C","Temp (°C)",    "gnb1 CPU Package 0 Temperature over Time",                RED,    "E3_gnb1_temp_timeseries.png")
print("E4: RAM used …")
ts_fig("node_mem_used_MB",    "RAM Used (MB)","gnb1 RAM Used (MB) over Time",                            GREEN,  "E4_gnb1_ram_used_timeseries.png")
print("E5: NET_RX softirq …")
ts_fig("node_softirq_NET_RX_per_s","NET_RX softirq/s","gnb1 NET_RX Softirq Rate over Time (ZMQ polling)",PURPLE,"E5_gnb1_net_rx_softirq.png")
print("E6: Interrupts/s …")
ts_fig("node_intr_per_s",     "Interrupts/s", "gnb1 Total Hardware Interrupts per Second",               BLUE,   "E6_gnb1_interrupts.png")
print("E7: CtxSwitches …")
ts_fig("node_ctxt_per_s",     "CtxSwitches/s","gnb1 Context Switches per Second",                        ORANGE, "E7_gnb1_ctxswitches.png")

# E8: All per-core CPU heatmap
print("E8: per-core CPU heatmap …")
core_cols = [f"node_cpu{i}_pct" for i in range(32)]
core_data = []
for col in core_cols:
    vals = [flt(r.get(col,"NA")) for r in deep_gnb if flt(r.get(col,"NA")) is not None]
    core_data.append(vals[:200] if vals else [0]*200)

max_len = max(len(v) for v in core_data)
mat = np.full((32, max_len), np.nan)
for i, v in enumerate(core_data):
    mat[i, :len(v)] = v

fig, ax = plt.subplots(figsize=(16, 8))
im = ax.imshow(mat, aspect="auto", cmap="YlOrRd", vmin=0, vmax=100,
               extent=[0, max_len*5, 31.5, -0.5])
ax.set_yticks(range(32))
ax.set_yticklabels([f"CPU{i}" for i in range(32)], fontsize=7)
ax.set_xlabel("Time (seconds)")
ax.set_ylabel("CPU Core")
ax.set_title("gnb1 Per-Core CPU % Heatmap over Time (32 cores)")
cb = fig.colorbar(im, ax=ax)
cb.set_label("CPU %")
fig.tight_layout()
save(fig, "E8_gnb1_percore_cpu_heatmap.png")

# ══════════════════════════════════════════════════════════════════════════════
#  SECTION F: SUMMARY OVERVIEW
# ══════════════════════════════════════════════════════════════════════════════
print("\n── Section F: Summary ──")

# F1: 4-panel overview — tput@100M, avg latency, CQI, PRB util
print("F1: 4-panel overview …")
fig, axes = plt.subplots(2, 2, figsize=(16, 10))
fig.suptitle("OpenRAN Testbed — Per-UE Summary (All 49 UEs)", fontsize=13, fontweight="bold")

# Panel 1: Throughput @100M
ax = axes[0,0]
tput_data = [(uid, ue_tput[uid].get(100,0) or 0) for uid in range(1,51) if uid!=40]
tput_data.sort(key=lambda x:x[0])
u_ids = [u for u,_ in tput_data]; t_vals = [v for _,v in tput_data]
colors = [BLUE if v > 0 else RED for v in t_vals]
ax.bar(range(len(u_ids)), t_vals, color=colors, edgecolor="white", width=0.8)
ax.set_xticks(range(len(u_ids)))
ax.set_xticklabels([f"UE{u}" for u in u_ids], rotation=90, fontsize=6)
ax.set_ylabel("Throughput (Mbps)")
ax.set_title("UDP Throughput @ 100 Mbps")
ax.axhline(100, color=ORANGE, ls="--", lw=1)

# Panel 2: ICMP avg latency
ax = axes[0,1]
ping_sorted = sorted(ue_ping_base.keys())
ping_avgs = [ue_ping_base[u]["ping_avg_ms"] or 0 for u in ping_sorted]
ax.bar(range(len(ping_sorted)), ping_avgs, color=GREEN, edgecolor="white", width=0.8)
ax.set_xticks(range(len(ping_sorted)))
ax.set_xticklabels([f"UE{u}" for u in ping_sorted], rotation=90, fontsize=6)
ax.set_ylabel("Avg RTT (ms)")
ax.set_title("ICMP Latency — Baseline Idle")

# Panel 3: CQI
ax = axes[1,0]
cqi_all = [gval(u,"pucch_cqi") or 0 for u in ran_ues]
ax.bar(range(50), cqi_all, color=PURPLE, edgecolor="white", width=0.8)
ax.set_xticks(range(50))
ax.set_xticklabels([f"UE{u}" for u in ran_ues], rotation=90, fontsize=6)
ax.set_ylabel("CQI")
ax.set_title("CQI — 50 UE Slots")
ax.set_ylim(0, 17)

# Panel 4: PRB utilization
ax = axes[1,1]
prb_all = [gval(u,"prb_util_pct") or 0 for u in ran_ues]
ax.bar(range(50), prb_all, color=ORANGE, edgecolor="white", width=0.8)
ax.set_xticks(range(50))
ax.set_xticklabels([f"UE{u}" for u in ran_ues], rotation=90, fontsize=6)
ax.set_ylabel("PRB Utilization %")
ax.set_title("DL PRB Utilization % — 50 UE Slots")

fig.tight_layout()
save(fig, "F1_summary_4panel.png")

# ── Final summary ─────────────────────────────────────────────────────────────
all_pngs = sorted(OUTDIR.glob("*.png"))
print(f"\n{'='*55}")
print(f"  Total plots: {len(all_pngs)}")
for p in all_pngs:
    print(f"    {p.name}  ({p.stat().st_size//1024} KB)")
print(f"{'='*55}")
print(f"\n  Location: {OUTDIR}")
