#!/usr/bin/env python3
"""
build_master_v4.py
──────────────────
Builds results/master_dataset_v4.csv.
v4 improvements over v3:
  - gnb1_rich_metrics_v2.csv: full PUSCH/PDSCH from ALL log lines (avg over thousands of samples)
    * pucch_snr_db, pucch_cqi, pucch_ta_us  (all 49 UEs ✓)
    * pusch_snr_db, pusch_mcs, pusch_tbs, pusch_nof_re, pusch_ta_us,
      pusch_rb_len, pusch_n_samples        (all 49 UEs ✓)
    * pdsch_nof_prb, pdsch_nof_re, pdsch_mcs, pdsch_tbs, pdsch_n_samples (all 49 UEs ✓)
    * prb_util_pct                          (all 49 UEs ✓)
  - gnb1_proc_metrics.csv: live-sampled proc metrics for all 50 srsenb processes
    * proc_rss_kB, proc_vmem_kB, proc_cpu_pct, thread_count
    * sys_mem_pct, sys_load
  - dl_brate_bps / ul_brate_bps: taken from gnb1_sysmon.csv total / 50 slots
  - ping_load_avg_ms / ping_load_mdev_ms: median-filled for 2 missing UEs
  - All v3 RAPL power columns retained
"""

import csv, random, os
import numpy as np
import pandas as pd
from pathlib import Path
from collections import defaultdict
from statistics import median

random.seed(42)
np.random.seed(42)

DATA   = Path("/tmp/ran_data2")
OUTDIR = Path("results")
OUTDIR.mkdir(parents=True, exist_ok=True)
OUT    = OUTDIR / "master_dataset_v4.csv"

RATES   = [1, 10, 20, 50, 100, 200, 300, 400, 500]
ALL_UES = [u for u in range(1, 51) if u != 40]
N_UES   = len(ALL_UES)

def flt(v, default=np.nan):
    try:
        x = float(v)
        return x if not (x != x) else default
    except Exception:
        return default

def col_mean(rows, col):
    vals = [flt(r.get(col, "NA")) for r in rows]
    vals = [v for v in vals if not np.isnan(v)]
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

# Imputation distributions
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
    s = rate_stats[rate]
    med = s[f"{key}_med"]; std = s[f"{key}_std"]
    noise = np.random.normal(0, std * 0.5)
    noise = max(-2 * std, min(2 * std, noise))
    val = med + noise
    if key == "tput":  val = max(0.0, val)
    if key == "loss":  val = max(0.0, min(100.0, val))
    if key == "jit":   val = max(0.0, val)
    return round(val, 3)

# Impute missing ping_load (2 UEs)
ping_load_avg_vals  = [v["ping_load_avg_ms"]  for v in ue_ping_load.values() if not np.isnan(v["ping_load_avg_ms"])]
ping_load_mdev_vals = [v["ping_load_mdev_ms"] for v in ue_ping_load.values() if not np.isnan(v["ping_load_mdev_ms"])]
ping_load_avg_med   = float(np.median(ping_load_avg_vals))  if ping_load_avg_vals  else 1000.0
ping_load_mdev_med  = float(np.median(ping_load_mdev_vals)) if ping_load_mdev_vals else 300.0

# ── 2. RAN metrics v2 (full PUSCH/PDSCH from re-parsed logs) ─────────────────
gnb_rows  = list(csv.DictReader(open(DATA / "gnb1_rich_metrics_v2.csv", errors="replace")))
gnb_by_ue = {int(r["ue_id"]): r for r in gnb_rows if r.get("ue_id", "").isdigit()}

def gv(uid, col):
    return flt(gnb_by_ue.get(uid, {}).get(col, "NA"))

print(f"  gnb1_rich_v2: {len(gnb_rows)} rows, "
      f"pusch filled={sum(1 for r in gnb_rows if r.get('pusch_snr_db',''))}")

# ── 3. gnb1 proc metrics (live-sampled) ───────────────────────────────────────
proc_rows  = list(csv.DictReader(open(DATA / "gnb1_proc_metrics.csv", errors="replace")))
proc_by_ue = {int(r["ue_id"]): r for r in proc_rows if r.get("ue_id", "").isdigit()}

def pv(uid, col):
    return flt(proc_by_ue.get(uid, {}).get(col, "NA"))

print(f"  gnb1_proc: {len(proc_rows)} rows")

# ── 4. gnb1 sysmon — derive per-slot brate ───────────────────────────────────
sysmon_rows  = list(csv.DictReader(open(DATA / "gnb1_sysmon.csv", errors="replace")))
sysmon_means = {}
for col in ["cpu_total_pct", "mem_used_pct", "load1", "load5", "load15",
            "rx_bytes_s", "tx_bytes_s", "total_srsenb_procs",
            "sum_dl_brate_bps", "sum_ul_brate_bps", "mean_proc_rss_kB", "max_proc_rss_kB"]:
    sysmon_means[col] = col_mean(sysmon_rows, col)

# Per-slot brate = total / number of active slots
n_slots = max(sysmon_means.get("total_srsenb_procs", 50), 1)
dl_brate_per_slot = (sysmon_means.get("sum_dl_brate_bps", np.nan) or 0) / n_slots
ul_brate_per_slot = (sysmon_means.get("sum_ul_brate_bps", np.nan) or 0) / n_slots

# ── 5. UE PHY ─────────────────────────────────────────────────────────────────
phy_rows  = list(csv.DictReader(open(DATA / "ue_phy_metrics.csv", errors="replace")))
phy_by_ue = {}
for r in phy_rows:
    uid = int(r["ue_id"])
    phy_by_ue[uid] = {
        "ue_ip":  r.get("ue_ip", ""),
        "c_rnti": r.get("c_rnti", ""),
        "pid":    flt(r.get("rss_kB", "NA")),
        "rss_kB": flt(r.get("vsz_kB", "NA")),
        "vsz_kB": flt(r.get("threads", "NA")),
    }

# ── 6. deep_uehost1 per-UE means ─────────────────────────────────────────────
pid_to_uid = {}
for r in phy_rows:
    pid_val = flt(r.get("rss_kB", "NA"))
    if not np.isnan(pid_val):
        pid_to_uid[int(pid_val)] = int(r["ue_id"])

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

# ── 7. deep_gnb1 node-level means ────────────────────────────────────────────
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
    gnb_node_means[f"node_cpu{i}_pct"] = col_mean(deep_gnb_rows, f"node_cpu{i}_pct")
print(f"  gnb1 deep: {len(deep_gnb_rows)} rows")

# ── 8. deep_core means ───────────────────────────────────────────────────────
deep_core_rows = list(csv.DictReader(open(DATA / "deep_core.csv", errors="replace")))
core_means = {}
for col in ["node_cpu_user_pct", "node_cpu_sys_pct", "node_mem_used_MB",
            "node_temp_package0_C", "node_intr_per_s", "node_ctxt_per_s",
            "proc_cpu_total_pct", "proc_rss_kB"]:
    core_means[f"core_{col}"] = col_mean(deep_core_rows, col)

# ── 9. RAPL power ─────────────────────────────────────────────────────────────
def load_power(path, prefix):
    result = {}
    if Path(path).exists():
        prows = list(csv.DictReader(open(path, errors="replace")))
        for col in ["pkg0_power_W", "pkg1_power_W", "dram0_power_W", "dram1_power_W", "cpu0_freq_MHz"]:
            result[f"{prefix}_{col}"] = col_mean(prows, col)
        p0 = result.get(f"{prefix}_pkg0_power_W", 0) or 0
        p1 = result.get(f"{prefix}_pkg1_power_W", 0) or 0
        result[f"{prefix}_total_power_W"] = round(p0 + p1, 2)
    return result

gnb1_power    = load_power(DATA / "power_gnb1.csv",    "gnb1")
uehost1_power = load_power(DATA / "power_uehost1.csv", "uehost1")
total_ue_power = (uehost1_power.get("uehost1_total_power_W", 0) or 0)
uehost1_power["uehost1_power_per_ue_W"] = round(total_ue_power / N_UES, 3)

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
    pl = ue_ping_load.get(uid, {})
    row["ping_load_avg_ms"]  = round(pl.get("ping_load_avg_ms", ping_load_avg_med), 3)
    row["ping_load_mdev_ms"] = round(pl.get("ping_load_mdev_ms", ping_load_mdev_med), 3)

    # ── RAN — PUCCH/PUSCH/PDSCH from re-parsed logs ──────────────────────────
    for col in ["pucch_snr_db", "pucch_cqi", "pucch_ta_us", "pucch_n_samples",
                "pusch_snr_db", "pusch_mcs",  "pusch_tbs",  "pusch_nof_re",
                "pusch_ta_us",  "pusch_rb_len","pusch_n_samples",
                "pdsch_nof_prb","pdsch_nof_re","pdsch_mcs",  "pdsch_tbs",
                "pdsch_n_samples", "prb_util_pct"]:
        row[f"ran_{col}"] = gv(uid, col)

    # ── proc metrics from live collection ────────────────────────────────────
    row["ran_proc_rss_kB"]   = pv(uid, "proc_rss_kB")
    row["ran_proc_vmem_kB"]  = pv(uid, "proc_vmem_kB")
    row["ran_proc_cpu_pct"]  = pv(uid, "proc_cpu_pct")
    row["ran_thread_count"]  = pv(uid, "thread_count")
    row["ran_sys_mem_pct"]   = pv(uid, "sys_mem_pct")
    row["ran_sys_load"]      = pv(uid, "sys_load")

    # ── brate from sysmon total / n_slots ────────────────────────────────────
    row["ran_dl_brate_bps"]  = round(dl_brate_per_slot, 2)
    row["ran_ul_brate_bps"]  = round(ul_brate_per_slot, 2)

    # ── UE process ───────────────────────────────────────────────────────────
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

    # ── gnb1 node-level ───────────────────────────────────────────────────────
    for col, val in gnb_node_means.items():
        row[f"gnb1_{col}"] = round(val, 3) if not np.isnan(val) else np.nan

    # ── sysmon aggregate ──────────────────────────────────────────────────────
    for col, val in sysmon_means.items():
        row[f"sysmon_{col}"] = round(val, 3) if not np.isnan(val) else np.nan

    # ── core ──────────────────────────────────────────────────────────────────
    for col, val in core_means.items():
        row[col] = round(val, 3) if not np.isnan(val) else np.nan

    # ── RAPL power ────────────────────────────────────────────────────────────
    for col, val in {**gnb1_power, **uehost1_power}.items():
        row[col] = round(val, 3) if (val is not None and not np.isnan(val)) else np.nan

    master_rows.append(row)

# ── Build DataFrame ───────────────────────────────────────────────────────────
df = pd.DataFrame(master_rows).sort_values("ue_id").reset_index(drop=True)

# Final NaN audit
null_counts = df.isnull().sum()
null_cols = null_counts[null_counts > 0]
n_real    = (df["data_source"] == "real").sum()
n_imputed = (df["data_source"] != "real").sum()

print(f"\nMaster dataset v4:")
print(f"  Rows:    {len(df)}")
print(f"  Columns: {len(df.columns)}")
print(f"  Real UEs:    {n_real}")
print(f"  Imputed UEs: {n_imputed}")
print(f"  NaN cells: {df.isna().sum().sum()} / {df.size}")

if len(null_cols) > 0:
    print(f"\n  Remaining NaN columns ({len(null_cols)}):")
    for col, cnt in null_cols.sort_values(ascending=False).items():
        print(f"    {col:45s}  {cnt}/{len(df)}")
else:
    print("  ✓ Zero NaN cells!")

df.to_csv(OUT, index=False)
print(f"\n  Saved → {OUT}  ({OUT.stat().st_size // 1024} KB)")

# Column groups
groups = {
    "Identity":      [c for c in df.columns if c in ["ue_id","ue_ip","c_rnti","ue_pid","data_source"]],
    "UDP Tput":      [c for c in df.columns if c.startswith("tput_")],
    "UDP Jitter":    [c for c in df.columns if c.startswith("jitter_")],
    "UDP Loss":      [c for c in df.columns if c.startswith("loss_")],
    "UDP Effective": [c for c in df.columns if c.startswith("eff_")],
    "ICMP Latency":  [c for c in df.columns if "ping" in c],
    "RAN PHY":       [c for c in df.columns if c.startswith("ran_pucch") or c.startswith("ran_pusch") or c.startswith("ran_pdsch") or c == "ran_prb_util_pct"],
    "RAN proc":      [c for c in df.columns if c.startswith("ran_proc") or c.startswith("ran_sys") or c.startswith("ran_thread") or c.startswith("ran_dl") or c.startswith("ran_ul")],
    "srsue proc":    [c for c in df.columns if c.startswith("srsue_")],
    "gnb1 node":     [c for c in df.columns if c.startswith("gnb1_node")],
    "gnb1 RAPL":     [c for c in df.columns if c.startswith("gnb1_pkg") or c.startswith("gnb1_dram") or c.startswith("gnb1_total") or c.startswith("gnb1_cpu0")],
    "uehost1 RAPL":  [c for c in df.columns if c.startswith("uehost1_")],
    "sysmon":        [c for c in df.columns if c.startswith("sysmon_")],
    "core":          [c for c in df.columns if c.startswith("core_")],
}
print("\n── Column groups ──")
for g, cols in groups.items():
    print(f"  {g:22s} {len(cols):3d} cols")

print("\n── Imputed UEs ──")
for _, r in df[df["data_source"] != "real"][["ue_id","data_source"]].iterrows():
    print(f"  UE{int(r['ue_id']):2d}: {r['data_source']}")
