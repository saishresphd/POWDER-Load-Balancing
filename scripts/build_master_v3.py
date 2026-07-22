#!/usr/bin/env python3
"""
build_master_v3.py
─────────────────────────────────────────────────────────────────────────────
Builds results/master_dataset_v3.csv — one row per UE (1–50, excluding 40).

v3 adds over v2:
  • power_gnb1.csv   — RAPL power: pkg0,pkg1,dram0,dram1 watts + cpu_freq_MHz (gnb1)
  • power_uehost1.csv — same for uehost1

All power columns are time-averaged (mean over the ~120s collection window).
New columns added to each row:
  gnb1_pkg0_power_W, gnb1_pkg1_power_W, gnb1_dram0_power_W, gnb1_dram1_power_W,
  gnb1_cpu_freq_MHz, gnb1_total_power_W (pkg0+pkg1)
  uehost1_pkg0_power_W, uehost1_pkg1_power_W, uehost1_dram0_power_W, uehost1_dram1_power_W,
  uehost1_cpu_freq_MHz, uehost1_total_power_W
  uehost1_power_per_ue_W   (total / 49 UEs — representative per-UE cost)
"""

import csv, random, os
import numpy as np
import pandas as pd
from pathlib import Path
from collections import defaultdict

random.seed(42)
np.random.seed(42)

DATA   = Path("/tmp/ran_data2")
OUTDIR = Path("results")
OUTDIR.mkdir(parents=True, exist_ok=True)
OUT    = OUTDIR / "master_dataset_v3.csv"

RATES       = [1, 10, 20, 50, 100, 200, 300, 400, 500]
ALL_UES     = [u for u in range(1, 51) if u != 40]   # 49 UEs
N_UES       = len(ALL_UES)

def flt(v, default=np.nan):
    try:
        x = float(v)
        return x if not (x != x) else default
    except Exception:
        return default

def col_mean(rows, col):
    vals = [flt(r.get(col, "NA")) for r in rows]
    vals = [v for v in vals if not np.isnan(v) and v >= 0]
    return float(np.mean(vals)) if vals else np.nan

print("Loading CSVs …")

# ── 1. UDP measurements ───────────────────────────────────────────────────────
udp_rows = list(csv.DictReader(open(DATA / "udp_latency_all_ues.csv", errors="replace")))

ue_tput   = defaultdict(dict)
ue_jitter = defaultdict(dict)
ue_loss   = defaultdict(dict)
ue_ping   = {}
ue_ping_load = {}

for r in udp_rows:
    uid   = int(r["ue_id"])
    ttype = r["test_type"]
    if ttype in ("udp_ramp", "udp_ramp_retest", "udp_ramp_fill"):
        rate = int(float(r["rate_target_mbps"]))
        tp   = flt(r["throughput_mbps"])
        jt   = flt(r["jitter_ms"])
        ls   = flt(r["pkt_loss_pct"])
        if not np.isnan(tp) and tp > 0:
            if rate not in ue_tput[uid] or tp > ue_tput[uid][rate]:
                ue_tput[uid][rate]   = tp
                ue_jitter[uid][rate] = jt
                ue_loss[uid][rate]   = ls
    elif ttype in ("ping_baseline", "ping_baseline_retest"):
        ue_ping[uid] = {
            "ping_avg_ms":  flt(r["ping_avg_ms"]),
            "ping_min_ms":  flt(r["ping_min_ms"]),
            "ping_max_ms":  flt(r["ping_max_ms"]),
            "ping_mdev_ms": flt(r["ping_mdev_ms"]),
        }
    elif ttype in ("ping_under_load", "ping_under_load_retest"):
        ue_ping_load[uid] = {
            "ping_load_avg_ms":  flt(r["ping_avg_ms"]),
            "ping_load_mdev_ms": flt(r["ping_mdev_ms"]),
        }

full_ues    = sum(1 for u in ALL_UES if len(ue_tput[u]) == 9)
partial_ues = sum(1 for u in ALL_UES if 0 < len(ue_tput[u]) < 9)
zero_ues    = sum(1 for u in ALL_UES if len(ue_tput[u]) == 0)
print(f"  UDP: {len(udp_rows)} rows → full={full_ues}  partial={partial_ues}  zero={zero_ues}")

# ── Imputation distributions ──────────────────────────────────────────────────
rate_stats = {}
for rate in RATES:
    tvals = [ue_tput[u][rate]   for u in ALL_UES if rate in ue_tput[u] and ue_tput[u][rate] > 0]
    jvals = [ue_jitter[u][rate] for u in ALL_UES if rate in ue_jitter[u] and not np.isnan(ue_jitter[u].get(rate, np.nan))]
    lvals = [ue_loss[u][rate]   for u in ALL_UES if rate in ue_loss[u]   and not np.isnan(ue_loss[u].get(rate, np.nan))]
    rate_stats[rate] = {
        "tput_med": float(np.median(tvals)) if tvals else float(rate),
        "tput_std": float(np.std(tvals))    if tvals else 0.05,
        "jit_med":  float(np.median(jvals)) if jvals else 15.0,
        "jit_std":  float(np.std(jvals))    if jvals else 3.0,
        "loss_med": float(np.median(lvals)) if lvals else 50.0,
        "loss_std": float(np.std(lvals))    if lvals else 10.0,
    }

def impute_val(rate, key="tput"):
    s   = rate_stats[rate]
    med = s[f"{key}_med"]; std = s[f"{key}_std"]
    noise = np.random.normal(0, std * 0.5)
    noise = max(-2 * std, min(2 * std, noise))
    val = med + noise
    if key == "tput":  val = max(0.0, val)
    if key == "loss":  val = max(0.0, min(100.0, val))
    if key == "jit":   val = max(0.0, val)
    return round(val, 3)

# ── 2. RAN metrics ────────────────────────────────────────────────────────────
gnb_rows  = list(csv.DictReader(open(DATA / "gnb1_rich_metrics.csv", errors="replace")))
gnb_by_ue = {int(r["ue_id"]): r for r in gnb_rows}

def gv(uid, col):
    return flt(gnb_by_ue.get(uid, {}).get(col, "NA"))

# ── 3. UE PHY ─────────────────────────────────────────────────────────────────
phy_rows  = list(csv.DictReader(open(DATA / "ue_phy_metrics.csv", errors="replace")))
phy_by_ue = {}
for r in phy_rows:
    uid = int(r["ue_id"])
    phy_by_ue[uid] = {
        "ue_ip":  r.get("ue_ip", ""),
        "c_rnti": r.get("c_rnti", ""),
        "pid":    flt(r.get("rss_kB", "NA")),   # column-shifted
        "rss_kB": flt(r.get("vsz_kB", "NA")),
        "vsz_kB": flt(r.get("threads", "NA")),
    }

# ── 4. deep_uehost1 per-UE means ─────────────────────────────────────────────
pid_to_uid = {int(flt(r.get("rss_kB", "0"), 0)): int(r["ue_id"])
              for r in phy_rows if flt(r.get("rss_kB", "NA")) is not np.nan}

ue_deep = defaultdict(lambda: defaultdict(list))
for r in csv.DictReader(open(DATA / "deep_uehost1.csv", errors="replace")):
    pid = flt(r.get("proc_pid", "NA"))
    if np.isnan(pid): continue
    uid = pid_to_uid.get(int(pid))
    if uid is None: continue
    for k in ["proc_rss_kB", "proc_vsz_kB", "proc_cpu_total_pct", "proc_cpu_user_pct",
              "proc_cpu_sys_pct", "proc_vol_ctxsw_s", "proc_nonvol_ctxsw_s",
              "proc_schedrun_ns", "proc_schedwait_ns", "proc_threads", "proc_vmlock_kB"]:
        v = flt(r.get(k, "NA"))
        if not np.isnan(v) and v >= 0:
            ue_deep[uid][k].append(v)

def pmean(uid, k):
    vals = ue_deep[uid].get(k, [])
    return float(np.mean(vals)) if vals else np.nan

# ── 5. deep_gnb1 node-level means ────────────────────────────────────────────
deep_gnb_rows = list(csv.DictReader(open(DATA / "deep_gnb1.csv", errors="replace")))
gnb_node_means = {}
node_cols = ["node_cpu_user_pct", "node_cpu_sys_pct", "node_cpu_softirq_pct",
             "node_cpu_idle_pct", "node_mem_used_MB", "node_swap_used_MB", "node_load1",
             "node_intr_per_s", "node_ctxt_per_s",
             "node_softirq_NET_RX_per_s", "node_softirq_NET_TX_per_s", "node_softirq_SCHED_per_s",
             "node_net_rx_bytes_s", "node_net_tx_bytes_s",
             "node_temp_package0_C", "node_temp_package1_C", "node_temp_core_max_C"]
for col in node_cols:
    gnb_node_means[col] = col_mean(deep_gnb_rows, col)
for i in range(32):
    col = f"node_cpu{i}_pct"
    gnb_node_means[col] = col_mean(deep_gnb_rows, col)
print(f"  gnb1 deep: {len(deep_gnb_rows)} rows")

# ── 6. gnb1_sysmon aggregate means ───────────────────────────────────────────
sysmon_rows  = list(csv.DictReader(open(DATA / "gnb1_sysmon.csv", errors="replace")))
sysmon_means = {}
for col in ["cpu_total_pct", "mem_used_pct", "load1", "load5", "load15",
            "rx_bytes_s", "tx_bytes_s", "total_srsenb_procs",
            "sum_dl_brate_bps", "sum_ul_brate_bps", "mean_proc_rss_kB", "max_proc_rss_kB"]:
    sysmon_means[col] = col_mean(sysmon_rows, col)

# ── 7. deep_core means ────────────────────────────────────────────────────────
deep_core_rows = list(csv.DictReader(open(DATA / "deep_core.csv", errors="replace")))
core_means = {}
for col in ["node_cpu_user_pct", "node_cpu_sys_pct", "node_mem_used_MB",
            "node_temp_package0_C", "node_intr_per_s", "node_ctxt_per_s",
            "proc_cpu_total_pct", "proc_rss_kB"]:
    core_means[f"core_{col}"] = col_mean(deep_core_rows, col)

# ── 8. RAPL power — gnb1 ─────────────────────────────────────────────────────
power_gnb1_path = DATA / "power_gnb1.csv"
gnb1_power = {}
if power_gnb1_path.exists():
    prows = list(csv.DictReader(open(power_gnb1_path, errors="replace")))
    print(f"  gnb1 power: {len(prows)} samples")
    for col in ["pkg0_power_W", "pkg1_power_W", "dram0_power_W", "dram1_power_W", "cpu0_freq_MHz"]:
        gnb1_power[f"gnb1_{col}"] = col_mean(prows, col)
    # Derived: total package power
    p0 = gnb1_power.get("gnb1_pkg0_power_W", 0) or 0
    p1 = gnb1_power.get("gnb1_pkg1_power_W", 0) or 0
    gnb1_power["gnb1_total_power_W"] = round(p0 + p1, 2)
else:
    print(f"  WARNING: {power_gnb1_path} not found — power_gnb1 columns will be NaN")
    for col in ["gnb1_pkg0_power_W", "gnb1_pkg1_power_W", "gnb1_dram0_power_W",
                "gnb1_dram1_power_W", "gnb1_cpu0_freq_MHz", "gnb1_total_power_W"]:
        gnb1_power[col] = np.nan

# ── 9. RAPL power — uehost1 ──────────────────────────────────────────────────
power_ue_path = DATA / "power_uehost1.csv"
uehost1_power = {}
if power_ue_path.exists():
    prows = list(csv.DictReader(open(power_ue_path, errors="replace")))
    print(f"  uehost1 power: {len(prows)} samples")
    for col in ["pkg0_power_W", "pkg1_power_W", "dram0_power_W", "dram1_power_W", "cpu0_freq_MHz"]:
        uehost1_power[f"uehost1_{col}"] = col_mean(prows, col)
    p0 = uehost1_power.get("uehost1_pkg0_power_W", 0) or 0
    p1 = uehost1_power.get("uehost1_pkg1_power_W", 0) or 0
    total = p0 + p1
    uehost1_power["uehost1_total_power_W"]    = round(total, 2)
    uehost1_power["uehost1_power_per_ue_W"]   = round(total / N_UES, 3)
else:
    print(f"  WARNING: {power_ue_path} not found — power_uehost1 columns will be NaN")
    for col in ["uehost1_pkg0_power_W", "uehost1_pkg1_power_W", "uehost1_dram0_power_W",
                "uehost1_dram1_power_W", "uehost1_cpu0_freq_MHz",
                "uehost1_total_power_W", "uehost1_power_per_ue_W"]:
        uehost1_power[col] = np.nan

# ── Build master rows ─────────────────────────────────────────────────────────
print("Building master rows …")
master_rows = []

for uid in ALL_UES:
    imputed_rates = []
    row = {"ue_id": uid, "data_source": "real"}

    # UDP per-rate
    for rate in RATES:
        if rate in ue_tput[uid] and ue_tput[uid][rate] > 0:
            tp = ue_tput[uid][rate]
            jt = ue_jitter[uid].get(rate, np.nan)
            ls = ue_loss[uid].get(rate, np.nan)
        else:
            tp = impute_val(rate, "tput")
            jt = impute_val(rate, "jit")
            ls = impute_val(rate, "loss")
            imputed_rates.append(rate)
        eff = round(tp * (1 - ls / 100), 3) if not np.isnan(ls) else np.nan
        row[f"tput_{rate}M"]   = round(tp, 3)
        row[f"jitter_{rate}M"] = round(jt, 3) if not np.isnan(jt) else np.nan
        row[f"loss_{rate}M"]   = round(ls, 2)  if not np.isnan(ls) else np.nan
        row[f"eff_{rate}M"]    = round(eff, 3) if not np.isnan(eff) else np.nan

    if imputed_rates:
        row["data_source"] = f"imputed_rates:{','.join(map(str, imputed_rates))}"

    # ICMP latency
    for k, v in ue_ping.get(uid, {}).items():
        row[k] = round(v, 3) if not np.isnan(v) else np.nan
    for k, v in ue_ping_load.get(uid, {}).items():
        row[k] = round(v, 3) if not np.isnan(v) else np.nan

    # RAN metrics
    for col in ["pucch_snr_db", "pucch_cqi", "pucch_ta_us",
                "pusch_snr_db", "pusch_mcs", "pusch_tbs", "pusch_nof_re", "pusch_ta_us",
                "pdsch_nof_prb", "pdsch_nof_re", "pdsch_mcs", "pdsch_tbs", "prb_util_pct",
                "dl_brate_bps", "ul_brate_bps",
                "proc_rss_kB", "proc_vmem_kB", "sys_mem_pct", "sys_load", "thread_count",
                "cpu_max", "cpu_mean", "cpu_p95"]:
        row[f"ran_{col}"] = gv(uid, col)

    # UE process
    phy = phy_by_ue.get(uid, {})
    row["ue_ip"]     = phy.get("ue_ip", "")
    row["c_rnti"]    = phy.get("c_rnti", "")
    row["ue_pid"]    = phy.get("pid", np.nan)
    row["ue_rss_kB"] = phy.get("rss_kB", np.nan)
    row["ue_vsz_kB"] = phy.get("vsz_kB", np.nan)

    for k in ["proc_rss_kB", "proc_vsz_kB", "proc_cpu_total_pct", "proc_cpu_user_pct",
              "proc_cpu_sys_pct", "proc_vol_ctxsw_s", "proc_nonvol_ctxsw_s",
              "proc_schedrun_ns", "proc_schedwait_ns", "proc_threads", "proc_vmlock_kB"]:
        row[f"srsue_{k}"] = pmean(uid, k)

    # gnb1 node-level
    for col, val in gnb_node_means.items():
        row[f"gnb1_{col}"] = round(val, 3) if not np.isnan(val) else np.nan

    # gnb1 sysmon
    for col, val in sysmon_means.items():
        row[f"sysmon_{col}"] = round(val, 3) if not np.isnan(val) else np.nan

    # core
    for col, val in core_means.items():
        row[col] = round(val, 3) if not np.isnan(val) else np.nan

    # ── RAPL power (gnb1) ────────────────────────────────────────────────────
    for col, val in gnb1_power.items():
        row[col] = round(val, 3) if (val is not None and not np.isnan(val)) else np.nan

    # ── RAPL power (uehost1) ─────────────────────────────────────────────────
    for col, val in uehost1_power.items():
        row[col] = round(val, 3) if (val is not None and not np.isnan(val)) else np.nan

    master_rows.append(row)

# ── Build DataFrame and save ──────────────────────────────────────────────────
df = pd.DataFrame(master_rows).sort_values("ue_id").reset_index(drop=True)

n_real    = (df["data_source"] == "real").sum()
n_imputed = (df["data_source"] != "real").sum()
print(f"\nMaster dataset v3:")
print(f"  Rows:    {len(df)}")
print(f"  Columns: {len(df.columns)}")
print(f"  Real UEs:    {n_real}")
print(f"  Imputed UEs: {n_imputed}")
print(f"  NaN cells: {df.isna().sum().sum()} / {df.size}")

df.to_csv(OUT, index=False)
print(f"\n  Saved → {OUT}  ({OUT.stat().st_size // 1024} KB)")

# Column summary
groups = {
    "Identity":      [c for c in df.columns if c in ["ue_id", "ue_ip", "c_rnti", "ue_pid", "data_source"]],
    "UDP Tput":      [c for c in df.columns if c.startswith("tput_")],
    "UDP Jitter":    [c for c in df.columns if c.startswith("jitter_")],
    "UDP Loss":      [c for c in df.columns if c.startswith("loss_")],
    "UDP Effective": [c for c in df.columns if c.startswith("eff_")],
    "ICMP Latency":  [c for c in df.columns if "ping" in c],
    "RAN":           [c for c in df.columns if c.startswith("ran_")],
    "srsue proc":    [c for c in df.columns if c.startswith("srsue_")],
    "gnb1 node":     [c for c in df.columns if c.startswith("gnb1_node")],
    "gnb1 RAPL":     [c for c in df.columns if c.startswith("gnb1_pkg") or c.startswith("gnb1_dram") or c.startswith("gnb1_total") or c.startswith("gnb1_cpu0")],
    "uehost1 RAPL":  [c for c in df.columns if c.startswith("uehost1_")],
    "sysmon":        [c for c in df.columns if c.startswith("sysmon_")],
    "core":          [c for c in df.columns if c.startswith("core_")],
    "UE RSS/VSZ":    [c for c in df.columns if c in ["ue_rss_kB", "ue_vsz_kB"]],
}
print("\n── Column groups ──")
for g, cols in groups.items():
    print(f"  {g:22s} {len(cols):3d} cols  {cols[:3]}")

print("\n── RAPL summary ──")
power_cols = [c for c in df.columns if "power" in c or "freq" in c]
for col in power_cols:
    print(f"  {col:40s}  mean={df[col].mean():.2f}  std={df[col].std():.2f}")

print("\n── Imputed UEs ──")
for _, r in df[df["data_source"] != "real"][["ue_id", "data_source"]].iterrows():
    print(f"  UE{int(r['ue_id']):2d}: {r['data_source']}")
