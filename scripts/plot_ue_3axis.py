#!/usr/bin/env python3
"""
plot_ue_3axis.py  —  Comprehensive UE-wise 3-axis plots for OpenRAN testbed
Generates multi-panel figures with 3 Y-axes per plot (twinx stacking).

Plot groups:
  Fig 1:  UDP Throughput ramp    — tput_mbps | jitter_ms | pkt_loss_pct
  Fig 2:  ICMP Latency per UE    — ping_avg_ms | ping_max_ms | ping_mdev_ms
  Fig 3:  Latency vs Load        — ping_avg_ms (idle vs under-load) | delta | jitter
  Fig 4:  RAN — UL channel       — pusch_snr_db | pusch_mcs | pusch_tbs
  Fig 5:  RAN — DL channel       — pdsch_nof_prb | prb_util_pct | pdsch_mcs
  Fig 6:  RAN — CQI / TA / PUCCH — pucch_snr_db | pucch_cqi | pucch_ta_us
  Fig 7:  gnb1 per-slot CPU      — cpu_max | cpu_mean | proc_rss_kB
  Fig 8:  srsue process stats    — proc_rss_kB | proc_vsz_kB | proc_vol_ctxsw_s
  Fig 9:  gnb1 node system       — node_cpu_user | node_cpu_sys | node_softirq_NET_RX
  Fig 10: gnb1 brate + mem       — dl_brate_bps | ul_brate_bps | sys_mem_pct
  Fig 11: gnb1 temp over time    — pkg0_C | pkg1_C | core_max_C
  Fig 12: IRQ + ctxsw over time  — intr_per_s | ctxt_per_s | softirq_SCHED
  Fig 13: 3D — UE x Rate x Tput  — 3D surface (UE id, target rate, actual throughput)
  Fig 14: 3D — UE x Rate x Jitter
  Fig 15: 3D — UE x Rate x Loss%
"""

import csv
import os
import sys
import warnings
from pathlib import Path
from collections import defaultdict

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
from mpl_toolkits.mplot3d import Axes3D          # noqa: F401
import numpy as np

warnings.filterwarnings("ignore")

# ── Paths ─────────────────────────────────────────────────────────────────────
DATA   = Path("/tmp/ran_data2")
OUTDIR = Path("/tmp/ran_data2/plots")
OUTDIR.mkdir(parents=True, exist_ok=True)

# ── Style ─────────────────────────────────────────────────────────────────────
plt.rcParams.update({
    "figure.facecolor":  "#ffffff",
    "axes.facecolor":    "#f9fafb",
    "axes.edgecolor":    "#d1d5db",
    "axes.grid":         True,
    "grid.color":        "#e5e7eb",
    "grid.linewidth":    0.6,
    "font.family":       "DejaVu Sans",
    "font.size":         9,
    "axes.titlesize":    10,
    "axes.labelsize":    9,
    "legend.fontsize":   8,
    "xtick.labelsize":   8,
    "ytick.labelsize":   8,
    "lines.linewidth":   1.6,
    "lines.markersize":  5,
})

C1, C2, C3 = "#3b82d4", "#e05c3a", "#2ca02c"   # blue, orange-red, green

# ── Helpers ───────────────────────────────────────────────────────────────────
def flt(v, default=None):
    try:
        x = float(v)
        return x if not (x != x) else default   # NaN → default
    except Exception:
        return default

def load_csv(name):
    p = DATA / name
    if not p.exists():
        print(f"[WARN] missing: {p}")
        return []
    return list(csv.DictReader(open(p, errors="replace")))

def save(fig, name):
    path = OUTDIR / name
    fig.savefig(path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  saved → {path.name}")

def make_3ax(figsize=(13, 5), title=""):
    fig, ax1 = plt.subplots(figsize=figsize)
    ax2 = ax1.twinx()
    ax3 = ax1.twinx()
    ax3.spines["right"].set_position(("axes", 1.10))
    ax3.spines["right"].set_visible(True)
    if title:
        fig.suptitle(title, fontsize=11, fontweight="bold", y=1.01)
    return fig, ax1, ax2, ax3

def finalize(fig, ax1, ax2, ax3, xlabel="UE ID"):
    ax1.set_xlabel(xlabel)
    lines  = ax1.get_lines() + ax2.get_lines() + ax3.get_lines()
    labels = [l.get_label() for l in lines]
    ax1.legend(lines, labels, loc="upper left", ncol=3, framealpha=0.8)
    fig.tight_layout()

# ── Load data ─────────────────────────────────────────────────────────────────
print("Loading data …")
udp_rows   = load_csv("udp_latency_all_ues.csv")
gnb_rich   = load_csv("gnb1_rich_metrics.csv")
ue_phy     = load_csv("ue_phy_metrics.csv")
deep_gnb   = load_csv("deep_gnb1.csv")
deep_ue    = load_csv("deep_uehost1.csv")

# ── Build per-UE UDP pivot ────────────────────────────────────────────────────
RATES = [1, 10, 20, 50, 100, 200, 300, 400, 500]

# Valid UEs = those with at least 5 non-zero throughput rows
ue_tput = defaultdict(dict)   # uid → rate → tput
ue_jit  = defaultdict(dict)
ue_loss = defaultdict(dict)
ue_ping_base = {}   # uid → {min,avg,max,mdev}
ue_ping_load = {}

for r in udp_rows:
    uid  = int(r["ue_id"])
    ttype = r["test_type"]
    rate  = flt(r["rate_target_mbps"])
    if ttype in ("udp_ramp", "udp_ramp_retest") and rate is not None:
        tp = flt(r["throughput_mbps"])
        jt = flt(r["jitter_ms"])
        ls = flt(r["pkt_loss_pct"])
        if tp is not None:
            if uid not in ue_tput or rate not in ue_tput[uid] or (ue_tput[uid].get(rate,0) or 0) == 0:
                ue_tput[uid][rate] = tp
                ue_jit[uid][rate]  = jt
                ue_loss[uid][rate] = ls
    elif ttype in ("ping_baseline", "ping_baseline_retest"):
        ue_ping_base[uid] = {
            "min":  flt(r["ping_min_ms"]),
            "avg":  flt(r["ping_avg_ms"]),
            "max":  flt(r["ping_max_ms"]),
            "mdev": flt(r["ping_mdev_ms"]),
        }
    elif ttype in ("ping_under_load", "ping_under_load_retest"):
        ue_ping_load[uid] = {
            "avg":  flt(r["ping_avg_ms"]),
            "mdev": flt(r["ping_mdev_ms"]),
        }

# Valid: at least 5 out of 9 rates have tput > 0
valid_ues = sorted(
    uid for uid in ue_tput
    if sum(1 for v in ue_tput[uid].values() if v and v > 0) >= 5
)
print(f"  Valid UEs for plotting: {len(valid_ues)} → {valid_ues}")

# ── gnb1_rich lookup ──────────────────────────────────────────────────────────
gnb_by_ue = {int(r["ue_id"]): r for r in gnb_rich}

# ── ue_phy lookup — fix column misalignment ──────────────────────────────────
# collect_ue_rsrp_snr.sh has shifted columns:
#   rss_kB col actually = PID, vsz_kB = actual RSS, threads = VSZ
ue_phy_by_ue = {}
for r in ue_phy:
    uid = int(r["ue_id"])
    ue_phy_by_ue[uid] = {
        "ue_ip":   r.get("ue_ip", ""),
        "pid":     flt(r.get("rss_kB", "NA")),     # shifted: rss_kB = pid
        "rss_kB":  flt(r.get("vsz_kB", "NA")),     # shifted: vsz_kB = rss
        "vsz_kB":  flt(r.get("threads", "NA")),    # shifted: threads = vsz
        "threads": flt((r.get(None) or ["NA"])[0] if r.get(None) else "NA"),
    }

# ── deep_uehost1 — per-UE means by matching PIDs ─────────────────────────────
# PIDs in deep match the PID values stored in ue_phy rss_kB col
pid_to_ue_id = {
    int(flt(r.get("rss_kB","0"),0)): int(r["ue_id"])
    for r in ue_phy
    if flt(r.get("rss_kB","NA")) is not None
}
ue_deep = defaultdict(lambda: defaultdict(list))
for r in deep_ue:
    pid_val = flt(r.get("proc_pid","NA"))
    if pid_val is None:
        continue
    uid = pid_to_ue_id.get(int(pid_val))
    if uid is None:
        continue
    for k in ["proc_rss_kB","proc_vsz_kB","proc_cpu_total_pct",
              "proc_vol_ctxsw_s","proc_nonvol_ctxsw_s",
              "proc_schedrun_ns","proc_schedwait_ns"]:
        v = flt(r.get(k,"NA"))
        if v is not None and v >= 0:
            ue_deep[uid][k].append(v)

def ue_deep_mean(uid, key):
    vals = ue_deep[uid].get(key, [])
    return sum(vals)/len(vals) if vals else None

# ── Aggregate deep_gnb1 timeseries ───────────────────────────────────────────
def ts_col(rows, col):
    vals = [flt(r.get(col,"NA")) for r in rows]
    return [v for v in vals if v is not None]

# ══════════════════════════════════════════════════════════════════════════════
# FIGURE 1: UDP Throughput Ramp — 3 Y-axes: tput | jitter | loss
# ══════════════════════════════════════════════════════════════════════════════
print("\nFig 1: UDP throughput ramp …")
RATE_IDX = list(range(len(RATES)))

fig, ax1, ax2, ax3 = make_3ax(figsize=(14, 5.5),
    title="Fig 1 — UDP Throughput Ramp per UE  (Axis 1: Actual Throughput | Axis 2: Jitter | Axis 3: Packet Loss)")

cmap = plt.cm.tab20(np.linspace(0, 1, len(valid_ues)))
for ci, uid in enumerate(valid_ues):
    tputs = [ue_tput[uid].get(r) for r in RATES]
    jits  = [ue_jit[uid].get(r)  for r in RATES]
    losses= [ue_loss[uid].get(r) for r in RATES]
    x = RATE_IDX
    ax1.plot(x, tputs, color=cmap[ci], marker="o", ms=3, alpha=0.8, label=f"UE{uid}")
    ax2.plot(x, jits,  color=cmap[ci], ls="--", alpha=0.5)
    ax3.plot(x, losses,color=cmap[ci], ls=":",  alpha=0.4)

ax1.set_ylabel("Actual Throughput (Mbps)", color=C1)
ax2.set_ylabel("Jitter (ms)",              color=C2)
ax3.set_ylabel("Packet Loss %",            color=C3)
ax1.tick_params(axis="y", colors=C1)
ax2.tick_params(axis="y", colors=C2)
ax3.tick_params(axis="y", colors=C3)
ax1.set_xticks(RATE_IDX)
ax1.set_xticklabels([f"{r}M" for r in RATES])
ax1.set_xlabel("Target UDP Rate")
ax1.legend(loc="upper left", ncol=5, fontsize=7, framealpha=0.8)
fig.tight_layout()
save(fig, "fig1_udp_throughput_ramp.png")

# ══════════════════════════════════════════════════════════════════════════════
# FIGURE 2: Throughput @ each rate — bar + error — 1 subplot per rate
# ══════════════════════════════════════════════════════════════════════════════
print("Fig 2: per-UE throughput at each rate (all rates, subplots)…")
fig, axes = plt.subplots(3, 3, figsize=(16, 11))
fig.suptitle("Fig 2 — Per-UE Actual Throughput at Each Target Rate", fontsize=11, fontweight="bold")
for ai, rate in enumerate(RATES):
    ax = axes[ai // 3][ai % 3]
    ax2t = ax.twinx()
    ax3t = ax.twinx()
    ax3t.spines["right"].set_position(("axes", 1.12))
    ax3t.spines["right"].set_visible(True)

    x = list(range(len(valid_ues)))
    tputs = [ue_tput[u].get(rate) or 0 for u in valid_ues]
    jits  = [ue_jit[u].get(rate)  or 0 for u in valid_ues]
    losses= [ue_loss[u].get(rate) or 0 for u in valid_ues]

    ax.bar(x, tputs, color=C1, alpha=0.7, label="Tput (Mbps)")
    ax2t.plot(x, jits,  color=C2, marker="^", ms=4, label="Jitter (ms)")
    ax3t.plot(x, losses,color=C3, marker="s", ms=3, label="Loss %")

    ax.set_title(f"@ {rate} Mbps target", fontsize=9, fontweight="bold")
    ax.set_xticks(x)
    ax.set_xticklabels([f"UE{u}" for u in valid_ues], rotation=60, fontsize=6)
    ax.set_ylabel("Tput (Mbps)", color=C1, fontsize=7)
    ax2t.set_ylabel("Jitter (ms)", color=C2, fontsize=7)
    ax3t.set_ylabel("Loss %", color=C3, fontsize=7)
    ax.tick_params(axis="y", colors=C1)
    ax2t.tick_params(axis="y", colors=C2)
    ax3t.tick_params(axis="y", colors=C3)

fig.tight_layout()
save(fig, "fig2_tput_per_rate_per_ue.png")

# ══════════════════════════════════════════════════════════════════════════════
# FIGURE 3: ICMP Latency per UE — 3-axis: avg | max | mdev
# ══════════════════════════════════════════════════════════════════════════════
print("Fig 3: ICMP latency per UE …")
ping_ues = sorted(ue_ping_base.keys())
x = list(range(len(ping_ues)))

fig, ax1, ax2, ax3 = make_3ax(figsize=(13, 5),
    title="Fig 3 — ICMP Latency per UE (Baseline Idle)\n  Axis 1: Avg RTT | Axis 2: Max RTT | Axis 3: Jitter (mdev)")

avgs  = [ue_ping_base[u]["avg"]  or 0 for u in ping_ues]
maxs  = [ue_ping_base[u]["max"]  or 0 for u in ping_ues]
mdevs = [ue_ping_base[u]["mdev"] or 0 for u in ping_ues]

ax1.bar(x, avgs,  color=C1, alpha=0.65, label="Avg RTT (ms)")
ax2.plot(x, maxs,  color=C2, marker="^", ms=5, label="Max RTT (ms)")
ax3.plot(x, mdevs, color=C3, marker="s", ms=4, label="Jitter/mdev (ms)")

ax1.set_ylabel("Avg RTT (ms)", color=C1)
ax2.set_ylabel("Max RTT (ms)", color=C2)
ax3.set_ylabel("Jitter mdev (ms)", color=C3)
ax1.tick_params(axis="y", colors=C1)
ax2.tick_params(axis="y", colors=C2)
ax3.tick_params(axis="y", colors=C3)
ax1.set_xticks(x)
ax1.set_xticklabels([f"UE{u}" for u in ping_ues], rotation=55, fontsize=7)
finalize(fig, ax1, ax2, ax3)
save(fig, "fig3_icmp_latency_per_ue.png")

# ══════════════════════════════════════════════════════════════════════════════
# FIGURE 4: Latency idle vs under-load — 3-axis: idle_avg | loaded_avg | delta
# ══════════════════════════════════════════════════════════════════════════════
print("Fig 4: latency idle vs load …")
common = sorted(set(ue_ping_base) & set(ue_ping_load))
x = list(range(len(common)))
idle_avg  = [ue_ping_base[u]["avg"]  or 0 for u in common]
load_avg  = [ue_ping_load[u]["avg"]  or 0 for u in common]
deltas    = [max(0, (ue_ping_load[u]["avg"] or 0) - (ue_ping_base[u]["avg"] or 0)) for u in common]
load_mdev = [ue_ping_load[u]["mdev"] or 0 for u in common]

fig, ax1, ax2, ax3 = make_3ax(figsize=(13, 5),
    title="Fig 4 — ICMP Latency: Idle vs Under 100 Mbps UDP Load\n  Axis 1: Idle avg RTT | Axis 2: Loaded avg RTT | Axis 3: Delta & Load Jitter")

ax1.bar(x, idle_avg, color=C1, alpha=0.55, label="Idle Avg RTT (ms)")
ax2.plot(x, load_avg, color=C2, marker="o", ms=4, label="Loaded Avg RTT (ms)")
ax3.bar(x, deltas,   color=C3, alpha=0.45, label="Delta (ms)", width=0.4)

ax1.set_ylabel("Idle Avg RTT (ms)", color=C1)
ax2.set_ylabel("Loaded Avg RTT (ms)", color=C2)
ax3.set_ylabel("RTT Increase (ms)", color=C3)
ax1.tick_params(axis="y", colors=C1)
ax2.tick_params(axis="y", colors=C2)
ax3.tick_params(axis="y", colors=C3)
ax1.set_xticks(x)
ax1.set_xticklabels([f"UE{u}" for u in common], rotation=55, fontsize=7)
finalize(fig, ax1, ax2, ax3)
save(fig, "fig4_latency_idle_vs_load.png")

# ══════════════════════════════════════════════════════════════════════════════
# FIGURE 5: RAN UL Channel per UE — 3-axis: PUSCH SNR | MCS | TBS
# ══════════════════════════════════════════════════════════════════════════════
print("Fig 5: RAN UL channel …")
ran_ues = sorted(gnb_by_ue.keys())
x = list(range(len(ran_ues)))

def ran_val(uid, key):
    return flt(gnb_by_ue.get(uid, {}).get(key, "NA"))

snr_ul  = [ran_val(u, "pusch_snr_db") for u in ran_ues]
mcs_ul  = [ran_val(u, "pusch_mcs")    for u in ran_ues]
tbs_ul  = [ran_val(u, "pusch_tbs")    for u in ran_ues]

fig, ax1, ax2, ax3 = make_3ax(figsize=(14, 5),
    title="Fig 5 — RAN UL Channel per UE (PUSCH)\n  Axis 1: PUSCH SNR (dB) | Axis 2: MCS | Axis 3: TBS (bytes)")

ax1.bar(x, [v or 0 for v in snr_ul], color=C1, alpha=0.6, label="PUSCH SNR (dB)")
ax2.plot(x, [v or 0 for v in mcs_ul], color=C2, marker="^", ms=5, label="UL MCS")
ax3.plot(x, [v or 0 for v in tbs_ul], color=C3, marker="s", ms=4, label="UL TBS (bytes)")

ax1.set_ylabel("PUSCH SNR (dB)", color=C1)
ax2.set_ylabel("UL MCS", color=C2)
ax3.set_ylabel("UL TBS (bytes)", color=C3)
ax1.tick_params(axis="y", colors=C1)
ax2.tick_params(axis="y", colors=C2)
ax3.tick_params(axis="y", colors=C3)
ax1.set_xticks(x)
ax1.set_xticklabels([f"UE{u}" for u in ran_ues], rotation=55, fontsize=7)
finalize(fig, ax1, ax2, ax3)
save(fig, "fig5_ran_ul_pusch.png")

# ══════════════════════════════════════════════════════════════════════════════
# FIGURE 6: RAN DL Channel per UE — 3-axis: PRB count | PRB util% | DL MCS
# ══════════════════════════════════════════════════════════════════════════════
print("Fig 6: RAN DL channel …")
prb_count = [ran_val(u, "pdsch_nof_prb")  for u in ran_ues]
prb_util  = [ran_val(u, "prb_util_pct")   for u in ran_ues]
mcs_dl    = [ran_val(u, "pdsch_mcs")      for u in ran_ues]

fig, ax1, ax2, ax3 = make_3ax(figsize=(14, 5),
    title="Fig 6 — RAN DL Channel per UE (PDSCH)\n  Axis 1: PRBs Allocated | Axis 2: PRB Utilization % | Axis 3: DL MCS")

ax1.bar(x, [v or 0 for v in prb_count], color=C1, alpha=0.6, label="PDSCH PRBs")
ax2.plot(x, [v or 0 for v in prb_util], color=C2, marker="o", ms=4, label="PRB Util %")
ax3.plot(x, [v or 0 for v in mcs_dl],   color=C3, marker="s", ms=4, label="DL MCS")

ax1.set_ylabel("PRBs Allocated (of 50)", color=C1)
ax2.set_ylabel("PRB Utilization %", color=C2)
ax3.set_ylabel("DL MCS", color=C3)
ax1.tick_params(axis="y", colors=C1)
ax2.tick_params(axis="y", colors=C2)
ax3.tick_params(axis="y", colors=C3)
ax1.set_xticks(x)
ax1.set_xticklabels([f"UE{u}" for u in ran_ues], rotation=55, fontsize=7)
finalize(fig, ax1, ax2, ax3)
save(fig, "fig6_ran_dl_pdsch.png")

# ══════════════════════════════════════════════════════════════════════════════
# FIGURE 7: RAN PUCCH per UE — 3-axis: CQI | PUCCH SNR | TA
# ══════════════════════════════════════════════════════════════════════════════
print("Fig 7: RAN PUCCH/CQI …")
cqi     = [ran_val(u, "pucch_cqi")    for u in ran_ues]
snr_pucch = [ran_val(u, "pucch_snr_db") for u in ran_ues]
ta      = [ran_val(u, "pucch_ta_us")  for u in ran_ues]

fig, ax1, ax2, ax3 = make_3ax(figsize=(14, 5),
    title="Fig 7 — RAN PUCCH per UE\n  Axis 1: CQI | Axis 2: PUCCH SNR (dB) | Axis 3: Timing Advance (µs)")

ax1.bar(x, [v or 0 for v in cqi],      color=C1, alpha=0.6, label="CQI (0–15)")
ax2.plot(x, [v or 0 for v in snr_pucch],color=C2, marker="^", ms=4, label="PUCCH SNR (dB)")
ax3.plot(x, [v or 0 for v in ta],       color=C3, marker="s", ms=4, label="Timing Advance (µs)")

ax1.set_ylabel("CQI", color=C1)
ax2.set_ylabel("PUCCH SNR (dB)", color=C2)
ax3.set_ylabel("Timing Advance (µs)", color=C3)
ax1.set_ylim(0, 16)
ax1.tick_params(axis="y", colors=C1)
ax2.tick_params(axis="y", colors=C2)
ax3.tick_params(axis="y", colors=C3)
ax1.set_xticks(x)
ax1.set_xticklabels([f"UE{u}" for u in ran_ues], rotation=55, fontsize=7)
finalize(fig, ax1, ax2, ax3)
save(fig, "fig7_ran_pucch_cqi.png")

# ══════════════════════════════════════════════════════════════════════════════
# FIGURE 8: gnb1 per-slot CPU/Mem — 3-axis: cpu_max | cpu_mean | proc_rss_MB
# ══════════════════════════════════════════════════════════════════════════════
print("Fig 8: gnb1 per-slot CPU/Mem …")
cpu_max  = [ran_val(u, "cpu_max")      for u in ran_ues]
cpu_mean = [ran_val(u, "cpu_mean")     for u in ran_ues]
rss_gnb  = [(ran_val(u, "proc_rss_kB") or 0)/1024 for u in ran_ues]   # MB

fig, ax1, ax2, ax3 = make_3ax(figsize=(14, 5),
    title="Fig 8 — gnb1 Per-Slot CPU & Memory\n  Axis 1: CPU Max % | Axis 2: CPU Mean % | Axis 3: Process RSS (MB)")

ax1.bar(x, [v or 0 for v in cpu_max],  color=C1, alpha=0.6, label="CPU Max %")
ax2.plot(x, [v or 0 for v in cpu_mean],color=C2, marker="o", ms=4, label="CPU Mean %")
ax3.plot(x, rss_gnb,                   color=C3, marker="s", ms=4, label="RSS (MB)")

ax1.set_ylabel("CPU Max %", color=C1)
ax2.set_ylabel("CPU Mean %", color=C2)
ax3.set_ylabel("Process RSS (MB)", color=C3)
ax1.tick_params(axis="y", colors=C1)
ax2.tick_params(axis="y", colors=C2)
ax3.tick_params(axis="y", colors=C3)
ax1.set_xticks(x)
ax1.set_xticklabels([f"UE{u}" for u in ran_ues], rotation=55, fontsize=7)
finalize(fig, ax1, ax2, ax3)
save(fig, "fig8_gnb1_slot_cpu_mem.png")

# ══════════════════════════════════════════════════════════════════════════════
# FIGURE 9: srsue per-process stats — RSS | VSZ | CPU total
# ══════════════════════════════════════════════════════════════════════════════
print("Fig 9: srsue process stats …")
ue_list = sorted(ue_deep.keys())
x = list(range(len(ue_list)))

rss_ue  = [(ue_deep_mean(u,"proc_rss_kB") or 0)/1024 for u in ue_list]
vsz_ue  = [(ue_deep_mean(u,"proc_vsz_kB") or 0)/1024 for u in ue_list]
cpu_ue  = [ue_deep_mean(u,"proc_cpu_total_pct") or 0  for u in ue_list]

fig, ax1, ax2, ax3 = make_3ax(figsize=(14, 5),
    title="Fig 9 — srsue Per-Process Stats (uehost1)\n  Axis 1: RSS (MB) | Axis 2: VSZ (MB) | Axis 3: CPU Total %")

ax1.bar(x, rss_ue, color=C1, alpha=0.65, label="RSS (MB)")
ax2.plot(x, vsz_ue, color=C2, marker="^", ms=4, label="VSZ (MB)")
ax3.plot(x, cpu_ue, color=C3, marker="s", ms=4, label="CPU %")

ax1.set_ylabel("RSS (MB)", color=C1)
ax2.set_ylabel("VSZ (MB)", color=C2)
ax3.set_ylabel("CPU Total %", color=C3)
ax1.tick_params(axis="y", colors=C1)
ax2.tick_params(axis="y", colors=C2)
ax3.tick_params(axis="y", colors=C3)
ax1.set_xticks(x)
ax1.set_xticklabels([f"UE{u}" for u in ue_list], rotation=55, fontsize=7)
finalize(fig, ax1, ax2, ax3)
save(fig, "fig9_srsue_proc_stats.png")

# ══════════════════════════════════════════════════════════════════════════════
# FIGURE 10: srsue context switches per UE — vol | nonvol | sched wait
# ══════════════════════════════════════════════════════════════════════════════
print("Fig 10: srsue ctx switches …")
vol_ue    = [ue_deep_mean(u,"proc_vol_ctxsw_s")    or 0 for u in ue_list]
nonvol_ue = [ue_deep_mean(u,"proc_nonvol_ctxsw_s") or 0 for u in ue_list]
wait_us   = [(ue_deep_mean(u,"proc_schedwait_ns") or 0)/1e6 for u in ue_list]  # ms

fig, ax1, ax2, ax3 = make_3ax(figsize=(14, 5),
    title="Fig 10 — srsue Context Switches & Sched Wait\n  Axis 1: Voluntary CtxSw/s | Axis 2: Non-vol CtxSw/s | Axis 3: Sched Wait (ms)")

ax1.bar(x, vol_ue,    color=C1, alpha=0.65, label="Vol CtxSw/s")
ax2.plot(x, nonvol_ue,color=C2, marker="^", ms=4, label="Non-vol CtxSw/s")
ax3.plot(x, wait_us,  color=C3, marker="s", ms=4, label="Sched Wait (ms)")

ax1.set_ylabel("Voluntary CtxSw/s", color=C1)
ax2.set_ylabel("Non-vol CtxSw/s", color=C2)
ax3.set_ylabel("Sched Wait (ms cumul)", color=C3)
ax1.tick_params(axis="y", colors=C1)
ax2.tick_params(axis="y", colors=C2)
ax3.tick_params(axis="y", colors=C3)
ax1.set_xticks(x)
ax1.set_xticklabels([f"UE{u}" for u in ue_list], rotation=55, fontsize=7)
finalize(fig, ax1, ax2, ax3)
save(fig, "fig10_srsue_ctxsw_sched.png")

# ══════════════════════════════════════════════════════════════════════════════
# FIGURE 11: gnb1 node timeseries — cpu_user | cpu_sys | softirq NET_RX
# ══════════════════════════════════════════════════════════════════════════════
print("Fig 11: gnb1 node timeseries CPU + softirq …")
t_idx = list(range(len(deep_gnb)))

cpu_u_ts   = ts_col(deep_gnb, "node_cpu_user_pct")
cpu_s_ts   = ts_col(deep_gnb, "node_cpu_sys_pct")
net_rx_ts  = ts_col(deep_gnb, "node_softirq_NET_RX_per_s")
t_u = list(range(len(cpu_u_ts)))

fig, ax1, ax2, ax3 = make_3ax(figsize=(14, 5),
    title="Fig 11 — gnb1 Node CPU over Time\n  Axis 1: CPU User % | Axis 2: CPU Sys % | Axis 3: Softirq NET_RX/s")

ax1.plot(t_u, cpu_u_ts,  color=C1, label="CPU User %")
ax2.plot(list(range(len(cpu_s_ts))),  cpu_s_ts,  color=C2, ls="--", label="CPU Sys %")
ax3.plot(list(range(len(net_rx_ts))), net_rx_ts, color=C3, ls=":",  label="NET_RX softirq/s")

ax1.set_ylabel("CPU User %", color=C1)
ax2.set_ylabel("CPU Sys %", color=C2)
ax3.set_ylabel("NET_RX softirq/s", color=C3)
ax1.tick_params(axis="y", colors=C1)
ax2.tick_params(axis="y", colors=C2)
ax3.tick_params(axis="y", colors=C3)
ax1.set_xlabel("Sample (every 5s)")
finalize(fig, ax1, ax2, ax3, xlabel="Sample (every 5s)")
save(fig, "fig11_gnb1_cpu_softirq_timeseries.png")

# ══════════════════════════════════════════════════════════════════════════════
# FIGURE 12: gnb1 temp timeseries — pkg0 | pkg1 | core_max
# ══════════════════════════════════════════════════════════════════════════════
print("Fig 12: gnb1 temperature timeseries …")
temp0_ts  = ts_col(deep_gnb, "node_temp_package0_C")
temp1_ts  = ts_col(deep_gnb, "node_temp_package1_C")
tempmax_ts= ts_col(deep_gnb, "node_temp_core_max_C")

fig, ax1, ax2, ax3 = make_3ax(figsize=(14, 5),
    title="Fig 12 — gnb1 CPU Temperature over Time\n  Axis 1: Package 0 °C | Axis 2: Package 1 °C | Axis 3: Core Max °C")

ax1.plot(list(range(len(temp0_ts))),   temp0_ts,   color=C1, label="Pkg0 (°C)")
ax2.plot(list(range(len(temp1_ts))),   temp1_ts,   color=C2, ls="--", label="Pkg1 (°C)")
ax3.plot(list(range(len(tempmax_ts))), tempmax_ts, color=C3, ls=":", label="Core Max (°C)")

ax1.set_ylabel("Package 0 Temp (°C)", color=C1)
ax2.set_ylabel("Package 1 Temp (°C)", color=C2)
ax3.set_ylabel("Core Max Temp (°C)", color=C3)
ax1.tick_params(axis="y", colors=C1)
ax2.tick_params(axis="y", colors=C2)
ax3.tick_params(axis="y", colors=C3)
finalize(fig, ax1, ax2, ax3, xlabel="Sample (every 5s)")
save(fig, "fig12_gnb1_temp_timeseries.png")

# ══════════════════════════════════════════════════════════════════════════════
# FIGURE 13: gnb1 IRQ + ctxsw — intr/s | ctxt/s | SCHED softirq
# ══════════════════════════════════════════════════════════════════════════════
print("Fig 13: gnb1 IRQ / context switches timeseries …")
intr_ts  = ts_col(deep_gnb, "node_intr_per_s")
ctxt_ts  = ts_col(deep_gnb, "node_ctxt_per_s")
sched_ts = ts_col(deep_gnb, "node_softirq_SCHED_per_s")

fig, ax1, ax2, ax3 = make_3ax(figsize=(14, 5),
    title="Fig 13 — gnb1 IRQ & Context Switches over Time\n  Axis 1: Interrupts/s | Axis 2: CtxSwitches/s | Axis 3: SCHED softirq/s")

ax1.plot(list(range(len(intr_ts))),  intr_ts,  color=C1, label="Interrupts/s")
ax2.plot(list(range(len(ctxt_ts))),  ctxt_ts,  color=C2, ls="--", label="CtxSwitches/s")
ax3.plot(list(range(len(sched_ts))), sched_ts, color=C3, ls=":", label="SCHED softirq/s")

ax1.set_ylabel("Interrupts/s", color=C1)
ax2.set_ylabel("Context Switches/s", color=C2)
ax3.set_ylabel("SCHED softirq/s", color=C3)
ax1.tick_params(axis="y", colors=C1)
ax2.tick_params(axis="y", colors=C2)
ax3.tick_params(axis="y", colors=C3)
finalize(fig, ax1, ax2, ax3, xlabel="Sample (every 5s)")
save(fig, "fig13_gnb1_irq_ctxsw.png")

# ══════════════════════════════════════════════════════════════════════════════
# FIGURE 14: 3D Surface — UE × Rate × Throughput
# ══════════════════════════════════════════════════════════════════════════════
print("Fig 14: 3D UE × Rate × Throughput …")
UE_arr   = np.array(valid_ues)
RATE_arr = np.array(RATES)
UE_grid, RATE_grid = np.meshgrid(UE_arr, RATE_arr, indexing="ij")
TPUT_grid = np.array([[ue_tput[u].get(r) or 0 for r in RATES] for u in valid_ues])

fig = plt.figure(figsize=(12, 7))
fig.suptitle("Fig 14 — 3D: UE × Target Rate × Actual Throughput (Mbps)", fontsize=11, fontweight="bold")
ax = fig.add_subplot(111, projection="3d")
surf = ax.plot_surface(UE_grid, RATE_grid, TPUT_grid,
                       cmap="viridis", alpha=0.85, edgecolor="none")
ax.set_xlabel("UE ID", labelpad=8)
ax.set_ylabel("Target Rate (Mbps)", labelpad=8)
ax.set_zlabel("Actual Throughput (Mbps)", labelpad=8)
ax.set_yticks(RATES)
fig.colorbar(surf, ax=ax, shrink=0.4, label="Tput (Mbps)")
fig.tight_layout()
save(fig, "fig14_3d_ue_rate_throughput.png")

# ══════════════════════════════════════════════════════════════════════════════
# FIGURE 15: 3D Surface — UE × Rate × Jitter
# ══════════════════════════════════════════════════════════════════════════════
print("Fig 15: 3D UE × Rate × Jitter …")
JIT_grid = np.array([[ue_jit[u].get(r) or 0 for r in RATES] for u in valid_ues])

fig = plt.figure(figsize=(12, 7))
fig.suptitle("Fig 15 — 3D: UE × Target Rate × Jitter (ms)", fontsize=11, fontweight="bold")
ax = fig.add_subplot(111, projection="3d")
surf = ax.plot_surface(UE_grid, RATE_grid, JIT_grid,
                       cmap="plasma", alpha=0.85, edgecolor="none")
ax.set_xlabel("UE ID", labelpad=8)
ax.set_ylabel("Target Rate (Mbps)", labelpad=8)
ax.set_zlabel("Jitter (ms)", labelpad=8)
ax.set_yticks(RATES)
fig.colorbar(surf, ax=ax, shrink=0.4, label="Jitter (ms)")
fig.tight_layout()
save(fig, "fig15_3d_ue_rate_jitter.png")

# ══════════════════════════════════════════════════════════════════════════════
# FIGURE 16: 3D Surface — UE × Rate × Packet Loss %
# ══════════════════════════════════════════════════════════════════════════════
print("Fig 16: 3D UE × Rate × Loss% …")
LOSS_grid = np.array([[ue_loss[u].get(r) or 0 for r in RATES] for u in valid_ues])

fig = plt.figure(figsize=(12, 7))
fig.suptitle("Fig 16 — 3D: UE × Target Rate × Packet Loss %", fontsize=11, fontweight="bold")
ax = fig.add_subplot(111, projection="3d")
surf = ax.plot_surface(UE_grid, RATE_grid, LOSS_grid,
                       cmap="Reds", alpha=0.85, edgecolor="none")
ax.set_xlabel("UE ID", labelpad=8)
ax.set_ylabel("Target Rate (Mbps)", labelpad=8)
ax.set_zlabel("Packet Loss %", labelpad=8)
ax.set_yticks(RATES)
fig.colorbar(surf, ax=ax, shrink=0.4, label="Loss %")
fig.tight_layout()
save(fig, "fig16_3d_ue_rate_loss.png")

# ══════════════════════════════════════════════════════════════════════════════
# FIGURE 17: 3D Scatter — UE × Latency × Throughput @ 100M coloured by loss
# ══════════════════════════════════════════════════════════════════════════════
print("Fig 17: 3D scatter UE × latency × tput …")
sc_ues    = [u for u in valid_ues if u in ue_ping_base]
sc_tput   = [ue_tput[u].get(100) or 0  for u in sc_ues]
sc_latency= [ue_ping_base[u]["avg"] or 0 for u in sc_ues]
sc_loss   = [ue_loss[u].get(100) or 0   for u in sc_ues]
sc_x      = list(range(len(sc_ues)))

fig = plt.figure(figsize=(12, 7))
fig.suptitle("Fig 17 — 3D: UE × Latency (idle) × Throughput @100M  (colour = Loss %)", fontsize=11, fontweight="bold")
ax = fig.add_subplot(111, projection="3d")
sc = ax.scatter(sc_x, sc_latency, sc_tput,
                c=sc_loss, cmap="coolwarm", s=80, depthshade=True, edgecolors="k", linewidth=0.3)
ax.set_xticks(sc_x)
ax.set_xticklabels([f"UE{u}" for u in sc_ues], rotation=35, fontsize=6)
ax.set_xlabel("UE", labelpad=8)
ax.set_ylabel("Idle Avg Latency (ms)", labelpad=8)
ax.set_zlabel("Throughput @100M (Mbps)", labelpad=8)
fig.colorbar(sc, ax=ax, shrink=0.4, label="Packet Loss %")
fig.tight_layout()
save(fig, "fig17_3d_ue_latency_tput.png")

# ══════════════════════════════════════════════════════════════════════════════
# FIGURE 18: gnb1 Memory over time — used_MB | free_MB | swap_MB
# ══════════════════════════════════════════════════════════════════════════════
print("Fig 18: gnb1 memory timeseries …")
mem_used = ts_col(deep_gnb, "node_mem_used_MB")
mem_free = ts_col(deep_gnb, "node_mem_free_MB")
swap_used= ts_col(deep_gnb, "node_swap_used_MB")

fig, ax1, ax2, ax3 = make_3ax(figsize=(14, 5),
    title="Fig 18 — gnb1 Memory over Time\n  Axis 1: RAM Used (MB) | Axis 2: RAM Free (MB) | Axis 3: Swap Used (MB)")

ax1.fill_between(range(len(mem_used)), mem_used, color=C1, alpha=0.4, label="RAM Used (MB)")
ax2.plot(range(len(mem_free)), mem_free,  color=C2, ls="--", label="RAM Free (MB)")
ax3.plot(range(len(swap_used)),swap_used, color=C3, marker=".", ms=3, label="Swap Used (MB)")

ax1.set_ylabel("RAM Used (MB)", color=C1)
ax2.set_ylabel("RAM Free (MB)", color=C2)
ax3.set_ylabel("Swap Used (MB)", color=C3)
ax1.tick_params(axis="y", colors=C1)
ax2.tick_params(axis="y", colors=C2)
ax3.tick_params(axis="y", colors=C3)
finalize(fig, ax1, ax2, ax3, xlabel="Sample (every 5s)")
save(fig, "fig18_gnb1_memory_timeseries.png")

print(f"\n{'='*55}")
print(f"  All plots saved → {OUTDIR}")
print(f"  Total plots: 18")
figs = sorted(OUTDIR.glob("*.png"))
for f in figs:
    print(f"    {f.name}  ({f.stat().st_size//1024} KB)")
print(f"{'='*55}")
