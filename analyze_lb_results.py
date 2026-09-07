#!/usr/bin/env python3
"""
analyze_lb_results.py — POWDER Load-Balancing Experiment Analysis
=================================================================
Post-experiment analysis script. Reads all CSVs harvested from:
  - gnb1, gnb2  : system_metrics, gnb_metrics, gnb_rich, power, deep_sysmon, perf_ipc
  - uehost2     : ue51_handover, iperf_results_500

Produces:
  1. key_findings.txt  — human-readable research summary
  2. lb_analysis.csv   — per-phase aggregated metrics table
  3. plots/            — matplotlib PNGs (if matplotlib available)

Key research findings targeted:
  KF-1  HANDOVER_LATENCY_MS
  KF-2  E2E_LB_LATENCY_MS
  KF-3  CPU_POWER_DELTA_GNB1 (W saved on gNB1 after LB)
  KF-4  GNB2_MARGINAL_POWER  (W added on gNB2)
  KF-5  THROUGHPUT_DEGRADATION_WINDOW_MS
  KF-6  SRSENB_SYS_LOAD_VS_NOF_UE
  KF-7  PER_CORE_CPU_IMBALANCE_PCT
  KF-8  CONTEXT_SWITCH_RATE_VS_UE_COUNT
  KF-9  IPC_VS_NOF_UE
  KF-10 CACHE_MISS_RATE_VS_LOAD

Usage:
  python3 analyze_lb_results.py --results-dir ./results [--plots] [--verbose]
"""

import argparse
import csv
import json
import math
import os
import sys
import textwrap
from collections import defaultdict
from datetime import datetime

# ──────────────────────────────────────────────────────────────
# Argument Parsing
# ──────────────────────────────────────────────────────────────

def parse_args():
    p = argparse.ArgumentParser(description="Analyze POWDER LB experiment results")
    p.add_argument("--results-dir", default="./results",
                   help="Root directory with gnb1/, gnb2/, uehost2/, core/ subdirs")
    p.add_argument("--plots", action="store_true",
                   help="Generate matplotlib plots (requires matplotlib)")
    p.add_argument("--verbose", "-v", action="store_true",
                   help="Print extra diagnostic output")
    p.add_argument("--out-dir", default=None,
                   help="Output directory for reports (default: --results-dir)")
    return p.parse_args()


# ──────────────────────────────────────────────────────────────
# CSV Helpers
# ──────────────────────────────────────────────────────────────

def load_csv(path, verbose=False):
    """Load a CSV into list-of-dicts. Returns [] if file missing."""
    if not os.path.isfile(path):
        if verbose:
            print(f"  [warn] missing: {path}")
        return []
    rows = []
    try:
        with open(path, newline="") as f:
            reader = csv.DictReader(f)
            for row in reader:
                rows.append(row)
    except Exception as e:
        if verbose:
            print(f"  [warn] cannot read {path}: {e}")
    return rows


def safe_float(val, default=None):
    try:
        return float(val)
    except (TypeError, ValueError):
        return default


def safe_int(val, default=None):
    try:
        return int(val)
    except (TypeError, ValueError):
        return default


def mean(values):
    vals = [v for v in values if v is not None]
    return sum(vals) / len(vals) if vals else None


def stdev(values):
    vals = [v for v in values if v is not None]
    if len(vals) < 2:
        return 0.0
    m = mean(vals)
    return math.sqrt(sum((x - m) ** 2 for x in vals) / (len(vals) - 1))


def pct_delta(before, after):
    """Percentage change: (after-before)/before * 100."""
    if before is None or after is None or before == 0:
        return None
    return (after - before) / abs(before) * 100.0


def phase_split(rows, phase_col="phase"):
    """Group rows by phase label."""
    groups = defaultdict(list)
    for r in rows:
        groups[r.get(phase_col, "unknown")].append(r)
    return groups


def numeric_col(rows, col):
    """Extract a numeric column from list-of-dicts, skipping nulls."""
    return [safe_float(r.get(col)) for r in rows if safe_float(r.get(col)) is not None]


# ──────────────────────────────────────────────────────────────
# Section 1 — Handover / LB Latency  (KF-1, KF-2)
# ──────────────────────────────────────────────────────────────

def analyze_handover(results_dir, verbose):
    ue2_dir = os.path.join(results_dir, "uehost2")
    summary_file = os.path.join(ue2_dir, "ue51_handover_summary.txt")
    handover_csv  = os.path.join(ue2_dir, "ue51_handover.csv")

    findings = {}

    # Read handover summary
    if os.path.isfile(summary_file):
        with open(summary_file) as f:
            for line in f:
                line = line.strip()
                if "=" in line:
                    k, v = line.split("=", 1)
                    findings[k.strip()] = v.strip()

    handover_ms = safe_float(findings.get("HANDOVER_DURATION_MS"))
    e2e_ms      = safe_float(findings.get("E2E_LB_LATENCY_MS"))
    lb_trigger  = findings.get("LB_TRIGGER_TS_MS")
    detach_ts   = findings.get("DETACH_TS_MS")
    attach_ts   = findings.get("ATTACH_TS_MS")

    # If summary missing, compute from CSV
    if handover_ms is None:
        rows = load_csv(handover_csv, verbose)
        if rows:
            detach_row = next((r for r in rows if r.get("event") == "ue51_detach"), None)
            attach_row = next((r for r in rows if r.get("event") == "ue51_attach_gnb2"), None)
            if detach_row and attach_row:
                t1 = safe_float(detach_row.get("timestamp_ms"))
                t2 = safe_float(attach_row.get("timestamp_ms"))
                if t1 and t2:
                    handover_ms = t2 - t1

    # Throughput gap during handover
    iperf_csv = os.path.join(results_dir, "iperf_results_500.csv")
    if not os.path.isfile(iperf_csv):
        iperf_csv = os.path.join(ue2_dir, "..", "iperf_results_500.csv")
    rows_iperf = load_csv(iperf_csv, verbose)
    tput_lb = numeric_col([r for r in rows_iperf if r.get("phase") == "lb_transition"], "throughput_mbps")
    tput_pre = numeric_col([r for r in rows_iperf if r.get("phase") == "pre_lb_steady"], "throughput_mbps")
    tput_post = numeric_col([r for r in rows_iperf if r.get("phase") == "post_lb_steady"], "throughput_mbps")

    throughput_drop_pct = None
    if tput_pre and tput_lb:
        throughput_drop_pct = pct_delta(mean(tput_pre), mean(tput_lb))

    return {
        "handover_duration_ms": handover_ms,
        "e2e_lb_latency_ms":    e2e_ms,
        "lb_trigger_ts_ms":     lb_trigger,
        "detach_ts_ms":         detach_ts,
        "attach_ts_ms":         attach_ts,
        "tput_pre_lb_mean_mbps":   mean(tput_pre),
        "tput_during_lb_mean_mbps": mean(tput_lb),
        "tput_post_lb_mean_mbps":  mean(tput_post),
        "throughput_drop_pct":  throughput_drop_pct,
    }


# ──────────────────────────────────────────────────────────────
# Section 2 — Power Analysis  (KF-3, KF-4)
# ──────────────────────────────────────────────────────────────

def analyze_power(results_dir, verbose):
    """Compare gNB1 and gNB2 power across phases."""
    result = {}
    for node in ("gnb1", "gnb2"):
        pwr_csv = os.path.join(results_dir, node, "power.csv")
        rows = load_csv(pwr_csv, verbose)
        phases = phase_split(rows)
        node_r = {}
        for phase in ("baseline", "pre_lb_steady", "lb_transition", "post_lb_steady"):
            p_rows = phases.get(phase, [])
            total_watts = []
            for r in p_rows:
                pkg0 = safe_float(r.get("pkg0_W", r.get("pkg0_w")))
                pkg1 = safe_float(r.get("pkg1_W", r.get("pkg1_w")))
                dram = safe_float(r.get("dram0_W", r.get("dram0_w", 0)))
                if pkg0 is not None:
                    total_watts.append((pkg0 or 0) + (pkg1 or 0) + (dram or 0))
            node_r[phase] = {"mean_W": mean(total_watts), "n": len(total_watts)}
        result[node] = node_r

    # KF-3: gNB1 power delta (pre_lb → post_lb)
    gnb1 = result.get("gnb1", {})
    pre_gnb1  = gnb1.get("pre_lb_steady", {}).get("mean_W")
    post_gnb1 = gnb1.get("post_lb_steady", {}).get("mean_W")
    result["gnb1_power_saved_W"] = (
        (pre_gnb1 - post_gnb1) if pre_gnb1 is not None and post_gnb1 is not None else None
    )
    result["gnb1_power_delta_pct"] = pct_delta(pre_gnb1, post_gnb1)

    # KF-4: gNB2 marginal power (baseline → post_lb)
    gnb2 = result.get("gnb2", {})
    base_gnb2 = gnb2.get("baseline", {}).get("mean_W")
    post_gnb2 = gnb2.get("post_lb_steady", {}).get("mean_W")
    result["gnb2_marginal_power_W"] = (
        (post_gnb2 - base_gnb2) if base_gnb2 is not None and post_gnb2 is not None else None
    )

    return result


# ──────────────────────────────────────────────────────────────
# Section 3 — gNB System Load vs nof_ue  (KF-6)
# ──────────────────────────────────────────────────────────────

def analyze_gnb_load(results_dir, verbose):
    """sys_load and nof_ue correlation per gNB."""
    result = {}
    for node in ("gnb1", "gnb2"):
        gnb_csv = os.path.join(results_dir, node, "gnb_metrics.csv")
        rows = load_csv(gnb_csv, verbose)
        nof_ue_vals  = numeric_col(rows, "nof_ue")
        sys_load     = numeric_col(rows, "sys_load")
        dl_brate     = numeric_col(rows, "dl_brate_Mbps")
        ul_brate     = numeric_col(rows, "ul_brate_Mbps")
        sched_util   = numeric_col(rows, "sched_util")

        # Per-phase breakdown
        phases = phase_split(rows)
        per_phase = {}
        for ph, ph_rows in phases.items():
            per_phase[ph] = {
                "nof_ue_mean":   mean(numeric_col(ph_rows, "nof_ue")),
                "sys_load_mean": mean(numeric_col(ph_rows, "sys_load")),
                "dl_brate_mean": mean(numeric_col(ph_rows, "dl_brate_Mbps")),
                "ul_brate_mean": mean(numeric_col(ph_rows, "ul_brate_Mbps")),
                "sched_util_mean": mean(numeric_col(ph_rows, "sched_util")),
            }

        result[node] = {
            "per_phase": per_phase,
            "max_nof_ue": max(nof_ue_vals) if nof_ue_vals else None,
            "max_sys_load": max(sys_load) if sys_load else None,
            "peak_dl_brate": max(dl_brate) if dl_brate else None,
        }
    return result


# ──────────────────────────────────────────────────────────────
# Section 4 — Per-core CPU imbalance  (KF-7)
# ──────────────────────────────────────────────────────────────

def analyze_cpu_imbalance(results_dir, verbose):
    """
    Compute coefficient of variation of per-core CPU usage across phases.
    High CV → IRQ/thread affinity imbalance → algorithm opportunity.
    """
    result = {}
    for node in ("gnb1", "gnb2"):
        deep_csv = os.path.join(results_dir, node, "deep_sysmon_{}.csv".format(node))
        if not os.path.isfile(deep_csv):
            deep_csv = os.path.join(results_dir, node, "deep_sysmon.csv")
        rows = load_csv(deep_csv, verbose)

        # Collect per-sample, per-core rows (look for cpu_id or core_id column)
        cpu_col = "cpu_id" if rows and "cpu_id" in rows[0] else "core_id"
        util_col = "cpu_pct" if rows and "cpu_pct" in rows[0] else "cpu_util_pct"

        phases_cv = {}
        phase_rows = phase_split(rows)
        for ph, ph_rows in phase_rows.items():
            # Collect all per-core util values in this phase
            core_utils = defaultdict(list)
            for r in ph_rows:
                cid = r.get(cpu_col)
                util = safe_float(r.get(util_col))
                if cid and util is not None:
                    core_utils[cid].append(util)
            # Mean util per core → CV across cores
            core_means = [mean(v) for v in core_utils.values() if v]
            if len(core_means) >= 2:
                m = mean(core_means)
                cv = (stdev(core_means) / m * 100.0) if m and m > 0 else 0.0
                phases_cv[ph] = {
                    "num_cores": len(core_means),
                    "mean_util_pct": m,
                    "cv_pct": cv,
                    "max_core_util": max(core_means),
                    "min_core_util": min(core_means),
                }

        result[node] = phases_cv
    return result


# ──────────────────────────────────────────────────────────────
# Section 5 — Context-switch rate vs UE count  (KF-8)
# ──────────────────────────────────────────────────────────────

def analyze_ctxsw(results_dir, verbose):
    """Context-switch / interrupt rate across phases per node."""
    result = {}
    for node in ("gnb1", "gnb2"):
        sys_csv = os.path.join(results_dir, node, "system_metrics.csv")
        rows = load_csv(sys_csv, verbose)
        phases = phase_split(rows)
        per_phase = {}
        for ph, ph_rows in phases.items():
            ctxsw   = mean(numeric_col(ph_rows, "ctxsw_per_s"))
            irq     = mean(numeric_col(ph_rows, "irq_per_s"))
            cpu_pct = mean(numeric_col(ph_rows, "cpu_pct"))
            nof_ue  = mean(numeric_col(ph_rows, "nof_ue"))
            per_phase[ph] = {
                "ctxsw_per_s": ctxsw,
                "irq_per_s":   irq,
                "cpu_pct":     cpu_pct,
                "nof_ue":      nof_ue,
            }
        result[node] = per_phase
    return result


# ──────────────────────────────────────────────────────────────
# Section 6 — IPC and cache miss rate  (KF-9, KF-10)
# ──────────────────────────────────────────────────────────────

def analyze_ipc(results_dir, verbose):
    """Load perf_ipc CSV, compute per-phase IPC and cache miss rate."""
    result = {}
    for node in ("gnb1", "gnb2"):
        ipc_csv = os.path.join(results_dir, node, "perf_ipc_{}.csv".format(node))
        if not os.path.isfile(ipc_csv):
            ipc_csv = os.path.join(results_dir, node, "perf_ipc.csv")
        rows = load_csv(ipc_csv, verbose)
        phases = phase_split(rows)
        per_phase = {}
        for ph, ph_rows in phases.items():
            ipc        = mean(numeric_col(ph_rows, "ipc"))
            cache_miss = mean(numeric_col(ph_rows, "cache_miss_rate_pct"))
            branch_miss= mean(numeric_col(ph_rows, "branch_miss_rate_pct"))
            cpu_util   = mean(numeric_col(ph_rows, "cpu_util_pct"))
            instructions = mean(numeric_col(ph_rows, "instructions"))
            cycles       = mean(numeric_col(ph_rows, "cycles"))
            per_phase[ph] = {
                "ipc": ipc,
                "cache_miss_rate_pct": cache_miss,
                "branch_miss_rate_pct": branch_miss,
                "cpu_util_pct": cpu_util,
                "instructions": instructions,
                "cycles": cycles,
            }

        # IPC summary file
        ipc_summary = os.path.join(results_dir, node, "perf_ipc_summary_{}.txt".format(node))
        summary_text = ""
        if os.path.isfile(ipc_summary):
            with open(ipc_summary) as f:
                summary_text = f.read()

        result[node] = {"per_phase": per_phase, "summary_text": summary_text}
    return result


# ──────────────────────────────────────────────────────────────
# Section 7 — Process-level srsenb metrics
# ──────────────────────────────────────────────────────────────

def analyze_process(results_dir, verbose):
    """CPU%, RSS, thread count, vol-ctxsw rate for srsenb process."""
    result = {}
    for node in ("gnb1", "gnb2"):
        deep_csv = os.path.join(results_dir, node, "deep_sysmon_{}.csv".format(node))
        if not os.path.isfile(deep_csv):
            deep_csv = os.path.join(results_dir, node, "deep_sysmon.csv")
        rows = load_csv(deep_csv, verbose)

        # Filter to srsenb process rows
        proc_rows = [r for r in rows if "srsenb" in r.get("proc_name", "")]
        phases = phase_split(proc_rows)
        per_phase = {}
        for ph, ph_rows in phases.items():
            cpu_usr = mean(numeric_col(ph_rows, "proc_cpu_user_pct"))
            cpu_sys = mean(numeric_col(ph_rows, "proc_cpu_sys_pct"))
            rss_mb  = mean(numeric_col(ph_rows, "proc_rss_mb"))
            threads = mean(numeric_col(ph_rows, "proc_threads"))
            vol_ctxsw = mean(numeric_col(ph_rows, "proc_vol_ctxsw_per_s"))
            run_ns  = mean(numeric_col(ph_rows, "proc_schedstat_run_ns"))
            wait_ns = mean(numeric_col(ph_rows, "proc_schedstat_wait_ns"))
            run_wait_ratio = None
            if run_ns and wait_ns and wait_ns > 0:
                run_wait_ratio = run_ns / wait_ns
            per_phase[ph] = {
                "cpu_user_pct": cpu_usr,
                "cpu_sys_pct":  cpu_sys,
                "rss_mb":       rss_mb,
                "threads":      threads,
                "vol_ctxsw_per_s": vol_ctxsw,
                "run_wait_ratio":  run_wait_ratio,
            }
        result[node] = per_phase
    return result


# ──────────────────────────────────────────────────────────────
# Section 8 — RAN metrics (MCS, SNR, PRB, CQI) from rich gNB CSV
# ──────────────────────────────────────────────────────────────

def analyze_ran_metrics(results_dir, verbose):
    result = {}
    for node in ("gnb1", "gnb2"):
        rich_csv = os.path.join(results_dir, node, "gnb_rich_{}.csv".format(node))
        rows = load_csv(rich_csv, verbose)
        phases = phase_split(rows)
        per_phase = {}
        for ph, ph_rows in phases.items():
            per_phase[ph] = {
                "dl_mcs_mean":  mean(numeric_col(ph_rows, "dl_mcs")),
                "ul_mcs_mean":  mean(numeric_col(ph_rows, "ul_mcs")),
                "ul_snr_mean":  mean(numeric_col(ph_rows, "ul_snr_db")),
                "dl_prb_mean":  mean(numeric_col(ph_rows, "dl_prb")),
                "ul_prb_mean":  mean(numeric_col(ph_rows, "ul_prb")),
                "cqi_mean":     mean(numeric_col(ph_rows, "cqi")),
                "phr_mean":     mean(numeric_col(ph_rows, "phr_db")),
            }
        result[node] = per_phase
    return result


# ──────────────────────────────────────────────────────────────
# Aggregated Phase Table
# ──────────────────────────────────────────────────────────────

PHASES_ORDERED = [
    "baseline",
    "ue51_connect",
    "ramp_20mbps",
    "ramp_100mbps",
    "ramp_200mbps",
    "ramp_300mbps",
    "ramp_400mbps",
    "ramp_500mbps",
    "pre_lb_steady",
    "lb_transition",
    "post_lb_steady",
]


def build_phase_table(power, gnb_load, ctxsw, ipc, proc):
    """Combine per-phase data for gnb1 into a single table."""
    rows = []
    for ph in PHASES_ORDERED:
        row = {"phase": ph}

        # Power
        gnb1_pwr = power.get("gnb1", {}).get(ph, {})
        gnb2_pwr = power.get("gnb2", {}).get(ph, {})
        row["gnb1_power_W"]   = _fmt(gnb1_pwr.get("mean_W"))
        row["gnb2_power_W"]   = _fmt(gnb2_pwr.get("mean_W"))

        # Load
        gnb1_load = gnb_load.get("gnb1", {}).get("per_phase", {}).get(ph, {})
        row["gnb1_nof_ue"]      = _fmt(gnb1_load.get("nof_ue_mean"), 1)
        row["gnb1_sys_load"]    = _fmt(gnb1_load.get("sys_load_mean"))
        row["gnb1_dl_brate_Mbps"] = _fmt(gnb1_load.get("dl_brate_mean"))
        row["gnb1_sched_util"]  = _fmt(gnb1_load.get("sched_util_mean"))

        # Context switches
        ctxsw_row = ctxsw.get("gnb1", {}).get(ph, {})
        row["gnb1_ctxsw_per_s"] = _fmt(ctxsw_row.get("ctxsw_per_s"))
        row["gnb1_irq_per_s"]   = _fmt(ctxsw_row.get("irq_per_s"))

        # IPC
        ipc_row = ipc.get("gnb1", {}).get("per_phase", {}).get(ph, {})
        row["gnb1_ipc"]             = _fmt(ipc_row.get("ipc"))
        row["gnb1_cache_miss_pct"]  = _fmt(ipc_row.get("cache_miss_rate_pct"))

        # Process
        proc_row = proc.get("gnb1", {}).get(ph, {})
        row["srsenb_cpu_user_pct"]   = _fmt(proc_row.get("cpu_user_pct"))
        row["srsenb_rss_mb"]         = _fmt(proc_row.get("rss_mb"), 1)
        row["srsenb_threads"]        = _fmt(proc_row.get("threads"), 1)
        row["srsenb_vol_ctxsw_per_s"]= _fmt(proc_row.get("vol_ctxsw_per_s"))

        rows.append(row)
    return rows


def _fmt(v, decimals=2):
    if v is None:
        return ""
    try:
        return round(float(v), decimals)
    except (ValueError, TypeError):
        return v


def write_phase_csv(rows, out_path):
    if not rows:
        return
    fieldnames = list(rows[0].keys())
    with open(out_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        w.writerows(rows)


# ──────────────────────────────────────────────────────────────
# Report Generation
# ──────────────────────────────────────────────────────────────

def _line(val, unit="", na="N/A"):
    if val is None:
        return na
    try:
        return f"{float(val):.2f} {unit}".strip()
    except (ValueError, TypeError):
        return str(val)


def write_key_findings(args, handover, power, gnb_load, cpu_imbal, ctxsw, ipc, proc, ran, out_dir):
    """Write the key_findings.txt report."""
    lines = []
    def s(text=""):
        lines.append(text)
    def h(title):
        lines.append("")
        lines.append("=" * 72)
        lines.append(f"  {title}")
        lines.append("=" * 72)

    s("POWDER LOAD-BALANCING EXPERIMENT — KEY FINDINGS")
    s(f"Generated: {datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S')} UTC")
    s(f"Results dir: {os.path.abspath(args.results_dir)}")

    # ── KF-1 & KF-2: Latency ─────────────────────────────────
    h("KF-1 / KF-2  HANDOVER & E2E LOAD-BALANCING LATENCY")
    s(f"  Handover duration (detach→attach):  {_line(handover['handover_duration_ms'], 'ms')}")
    s(f"  E2E LB latency   (trigger→attach):  {_line(handover['e2e_lb_latency_ms'], 'ms')}")
    s(f"  LB trigger timestamp:               {handover.get('lb_trigger_ts_ms', 'N/A')} ms")
    s(f"  UE51 detach timestamp:              {handover.get('detach_ts_ms', 'N/A')} ms")
    s(f"  UE51 attach to gNB2 timestamp:      {handover.get('attach_ts_ms', 'N/A')} ms")
    s("")
    s("  Interpretation:")
    hd = handover.get("handover_duration_ms")
    if hd is not None:
        if hd < 200:
            s("    → Fast handover (<200 ms): suitable for low-latency workloads.")
        elif hd < 500:
            s("    → Moderate handover (200-500 ms): acceptable for bulk data offload.")
        else:
            s("    → Slow handover (>500 ms): LB decision must account for UE disruption window.")
    s("  Algorithm implication: LB trigger must fire BEFORE power exceeds threshold")
    s("  by at least HANDOVER_DURATION_MS + scheduling_headroom.")

    # ── KF-5: Throughput degradation ─────────────────────────
    h("KF-5  THROUGHPUT DEGRADATION DURING HANDOVER WINDOW")
    s(f"  Pre-LB throughput:    {_line(handover['tput_pre_lb_mean_mbps'], 'Mbps')}")
    s(f"  During-LB throughput: {_line(handover['tput_during_lb_mean_mbps'], 'Mbps')}")
    s(f"  Post-LB throughput:   {_line(handover['tput_post_lb_mean_mbps'], 'Mbps')}")
    s(f"  Degradation:          {_line(handover['throughput_drop_pct'], '%')}")
    s("")
    s("  Algorithm implication: Cost function must penalise throughput loss.")
    s("  Recommended: weight = throughput_drop_pct × handover_duration_ms / 1000")

    # ── KF-3 & KF-4: Power ───────────────────────────────────
    h("KF-3 / KF-4  CPU POWER SAVINGS & MARGINAL POWER")
    s(f"  gNB1 power before LB:  {_line(power.get('gnb1',{}).get('pre_lb_steady',{}).get('mean_W'), 'W')}")
    s(f"  gNB1 power after LB:   {_line(power.get('gnb1',{}).get('post_lb_steady',{}).get('mean_W'), 'W')}")
    s(f"  gNB1 power SAVED:      {_line(power.get('gnb1_power_saved_W'), 'W')} "
      f"({_line(power.get('gnb1_power_delta_pct'), '%')} change)")
    s("")
    s(f"  gNB2 baseline power:   {_line(power.get('gnb2',{}).get('baseline',{}).get('mean_W'), 'W')}")
    s(f"  gNB2 power after LB:   {_line(power.get('gnb2',{}).get('post_lb_steady',{}).get('mean_W'), 'W')}")
    s(f"  gNB2 MARGINAL power:   {_line(power.get('gnb2_marginal_power_W'), 'W')}")
    s("")
    s("  Algorithm implication: Net power saving = gNB1_saved - gNB2_marginal.")
    saved = power.get("gnb1_power_saved_W")
    marginal = power.get("gnb2_marginal_power_W")
    if saved is not None and marginal is not None:
        net = saved - marginal
        s(f"  Net power delta:       {net:.2f} W  ({'SAVING' if net > 0 else 'OVERHEAD'})")
        if net > 0:
            s("  → LB is power-beneficial. Consider triggering when gNB1 load > threshold.")
        else:
            s("  → LB not power-beneficial at this load level. Raise LB threshold.")

    # ── KF-6: sys_load vs nof_ue ─────────────────────────────
    h("KF-6  SRSENB SYSTEM LOAD VS UE COUNT")
    for node in ("gnb1", "gnb2"):
        nd = gnb_load.get(node, {})
        s(f"\n  [{node.upper()}]  max_nof_ue={nd.get('max_nof_ue')}  "
          f"max_sys_load={_line(nd.get('max_sys_load'))}  "
          f"peak_dl_brate={_line(nd.get('peak_dl_brate'),'Mbps')}")
        for ph in PHASES_ORDERED:
            ph_d = nd.get("per_phase", {}).get(ph)
            if ph_d and ph_d.get("nof_ue_mean") is not None:
                s(f"    {ph:<20} nof_ue={_fmt(ph_d['nof_ue_mean'],1):>5}  "
                  f"sys_load={_fmt(ph_d['sys_load_mean']):>6}  "
                  f"dl_brate={_fmt(ph_d['dl_brate_mean']):>8} Mbps  "
                  f"sched_util={_fmt(ph_d['sched_util_mean']):>6}")
    s("")
    s("  Algorithm implication: Use sys_load as primary LB trigger metric.")
    s("  Fit: sys_load = f(nof_ue, dl_brate, sched_util) → regression model input.")

    # ── KF-7: Per-core CPU imbalance ─────────────────────────
    h("KF-7  PER-CORE CPU IMBALANCE (Coefficient of Variation)")
    for node in ("gnb1", "gnb2"):
        s(f"\n  [{node.upper()}]")
        nd = cpu_imbal.get(node, {})
        for ph in PHASES_ORDERED:
            ph_d = nd.get(ph)
            if ph_d:
                s(f"    {ph:<20} cores={ph_d['num_cores']:>3}  "
                  f"mean_util={_fmt(ph_d['mean_util_pct']):>6}%  "
                  f"CV={_fmt(ph_d['cv_pct']):>6}%  "
                  f"max_core={_fmt(ph_d['max_core_util']):>6}%  "
                  f"min_core={_fmt(ph_d['min_core_util']):>6}%")
    s("")
    s("  Algorithm implication: High CV → IRQ affinity not balanced.")
    s("  LB algorithm can co-optimise: UE offload + IRQ rebalance = double saving.")

    # ── KF-8: Context-switch rate ─────────────────────────────
    h("KF-8  CONTEXT-SWITCH RATE VS UE COUNT")
    for node in ("gnb1", "gnb2"):
        s(f"\n  [{node.upper()}]")
        nd = ctxsw.get(node, {})
        for ph in PHASES_ORDERED:
            ph_d = nd.get(ph)
            if ph_d and ph_d.get("ctxsw_per_s") is not None:
                s(f"    {ph:<20} ctxsw/s={_fmt(ph_d['ctxsw_per_s']):>10}  "
                  f"irq/s={_fmt(ph_d['irq_per_s']):>10}  "
                  f"cpu%={_fmt(ph_d['cpu_pct']):>6}")
    s("")
    s("  Algorithm implication: ctxsw/s scales with nof_ue beyond a break-point.")
    s("  Use ctxsw_per_s as a lightweight, kernel-level load proxy in LB decisions.")

    # ── KF-9 & KF-10: IPC / cache miss ───────────────────────
    h("KF-9 / KF-10  IPC DEGRADATION & CACHE MISS RATE")
    for node in ("gnb1", "gnb2"):
        s(f"\n  [{node.upper()}]")
        nd = ipc.get(node, {}).get("per_phase", {})
        for ph in PHASES_ORDERED:
            ph_d = nd.get(ph)
            if ph_d and ph_d.get("ipc") is not None:
                s(f"    {ph:<20} IPC={_fmt(ph_d['ipc']):>5}  "
                  f"cache_miss%={_fmt(ph_d['cache_miss_rate_pct']):>6}  "
                  f"branch_miss%={_fmt(ph_d['branch_miss_rate_pct']):>6}  "
                  f"cpu_util%={_fmt(ph_d['cpu_util_pct']):>6}")
        # Print embedded summary if present
        sumtxt = ipc.get(node, {}).get("summary_text", "")
        if sumtxt:
            s("")
            for ln in sumtxt.strip().splitlines():
                s(f"    [summary] {ln}")
    s("")
    s("  Algorithm implication: IPC drop with rising nof_ue → compute-bound workload.")
    s("  Use IPC as efficiency signal: LB when IPC < baseline_IPC * 0.85.")
    s("  Cache miss spike at LB transition = working-set disruption (OS page cache).")

    # ── srsenb process metrics ────────────────────────────────
    h("SRSENB PROCESS METRICS (CPU USER%, RSS, THREADS)")
    for node in ("gnb1", "gnb2"):
        s(f"\n  [{node.upper()}]")
        nd = proc.get(node, {})
        for ph in PHASES_ORDERED:
            ph_d = nd.get(ph)
            if ph_d and ph_d.get("cpu_user_pct") is not None:
                s(f"    {ph:<20} cpu_usr%={_fmt(ph_d['cpu_user_pct']):>6}  "
                  f"rss={_fmt(ph_d['rss_mb'],1):>7}MB  "
                  f"threads={_fmt(ph_d['threads'],0):>4}  "
                  f"vol_ctxsw/s={_fmt(ph_d['vol_ctxsw_per_s']):>8}  "
                  f"run/wait={_fmt(ph_d['run_wait_ratio']):>6}")

    # ── RAN metrics ───────────────────────────────────────────
    h("RAN METRICS (MCS, SNR, PRB, CQI) PER PHASE")
    for node in ("gnb1", "gnb2"):
        s(f"\n  [{node.upper()}]")
        nd = ran.get(node, {})
        for ph in PHASES_ORDERED:
            ph_d = nd.get(ph)
            if ph_d and ph_d.get("dl_mcs_mean") is not None:
                s(f"    {ph:<20} DL_MCS={_fmt(ph_d['dl_mcs_mean']):>5}  "
                  f"UL_MCS={_fmt(ph_d['ul_mcs_mean']):>5}  "
                  f"UL_SNR={_fmt(ph_d['ul_snr_mean']):>6}dB  "
                  f"DL_PRB={_fmt(ph_d['dl_prb_mean']):>5}  "
                  f"CQI={_fmt(ph_d['cqi_mean']):>4}  "
                  f"PHR={_fmt(ph_d['phr_mean']):>5}dB")

    # ── Algorithm Design Recommendations ─────────────────────
    h("ALGORITHM DESIGN RECOMMENDATIONS FOR CPU POWER SAVING")
    s(textwrap.dedent("""
  1. TRIGGER METRIC (primary):   sys_load > 0.80 × nof_ue_max_tested
     OR  cpu_pct > 75%  (sustained >10s)

  2. EARLY-WARNING SIGNAL:       IPC < baseline_IPC × 0.85
     Indicates compute saturation before CPU% saturates.

  3. EFFICIENCY PROXY (lightweight):  ctxsw_per_s > 2× baseline
     Kernel-level, no perf overhead, suitable for real-time decision.

  4. CACHE PRESSURE CHECK:       cache_miss_rate_pct > baseline × 1.5
     Pre-LB cache warming on target gNB reduces post-LB disruption.

  5. POWER MODEL:
     estimated_power = α × nof_ue + β × dl_brate + γ × sys_load + δ
     Fit α,β,γ,δ from this experiment's gnb1/power.csv.

  6. LB BENEFIT FUNCTION:
     benefit = gnb1_power_saved - gnb2_marginal_power - handover_penalty
     where handover_penalty = throughput_drop_pct × handover_duration_ms × weight

  7. CORE AFFINITY OPTIMISATION:
     High per-core CV (KF-7) → pin IRQ + srsenb threads to NUMA node.
     Reduces vol_ctxsw_per_s and improves IPC without UE migration.

  8. SLEEP STATE MANAGEMENT:
     After LB, gnb1 nof_ue drops → enable C2/C3 sleep on idle cores.
     Estimate savings: Δ_cores × core_idle_power (from RAPL pkg - active-core model).
    """).strip())

    # ── Footer ───────────────────────────────────────────────
    s("")
    s("=" * 72)
    s("END OF KEY FINDINGS REPORT")
    s(f"Generated by analyze_lb_results.py  |  Branch: 110-ue-scale")
    s("=" * 72)

    out_path = os.path.join(out_dir, "key_findings.txt")
    with open(out_path, "w") as f:
        f.write("\n".join(lines))
    print(f"[report] Wrote {out_path}")


# ──────────────────────────────────────────────────────────────
# Optional Matplotlib Plots
# ──────────────────────────────────────────────────────────────

def generate_plots(power, gnb_load, ipc, ctxsw, out_dir):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("[plots] matplotlib not installed — skipping plots")
        return

    plots_dir = os.path.join(out_dir, "plots")
    os.makedirs(plots_dir, exist_ok=True)

    phases = [ph for ph in PHASES_ORDERED]
    x = range(len(phases))
    xlabels = [ph.replace("_", "\n") for ph in phases]

    # Plot 1: gNB1 & gNB2 power across phases
    fig, ax = plt.subplots(figsize=(12, 5))
    for node, color in [("gnb1", "steelblue"), ("gnb2", "darkorange")]:
        vals = [power.get(node, {}).get(ph, {}).get("mean_W") for ph in phases]
        vals_clean = [v if v is not None else float("nan") for v in vals]
        ax.plot(x, vals_clean, marker="o", label=node, color=color)
    ax.set_xticks(list(x))
    ax.set_xticklabels(xlabels, fontsize=8)
    ax.set_ylabel("Total Power (W)")
    ax.set_title("gNB1 vs gNB2 Power Consumption per Phase")
    ax.legend()
    ax.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig(os.path.join(plots_dir, "power_per_phase.png"), dpi=120)
    plt.close()

    # Plot 2: gNB1 sys_load vs nof_ue
    nd1 = gnb_load.get("gnb1", {}).get("per_phase", {})
    nof_ue_vals = [nd1.get(ph, {}).get("nof_ue_mean") for ph in phases]
    sys_load_vals = [nd1.get(ph, {}).get("sys_load_mean") for ph in phases]
    nof_ue_clean = [v if v is not None else float("nan") for v in nof_ue_vals]
    sysload_clean = [v if v is not None else float("nan") for v in sys_load_vals]

    fig, ax1 = plt.subplots(figsize=(12, 5))
    ax2 = ax1.twinx()
    ax1.bar(x, nof_ue_clean, color="lightblue", label="nof_ue", zorder=2)
    ax2.plot(x, sysload_clean, color="red", marker="^", label="sys_load", zorder=3)
    ax1.set_xticks(list(x))
    ax1.set_xticklabels(xlabels, fontsize=8)
    ax1.set_ylabel("Number of UEs", color="steelblue")
    ax2.set_ylabel("System Load", color="red")
    ax1.set_title("gNB1 – System Load vs UE Count per Phase")
    fig.legend(loc="upper left", bbox_to_anchor=(0.08, 0.92))
    ax1.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig(os.path.join(plots_dir, "gnb1_load_vs_nof_ue.png"), dpi=120)
    plt.close()

    # Plot 3: IPC per phase (gnb1)
    nd_ipc = ipc.get("gnb1", {}).get("per_phase", {})
    ipc_vals = [nd_ipc.get(ph, {}).get("ipc") for ph in phases]
    cache_vals = [nd_ipc.get(ph, {}).get("cache_miss_rate_pct") for ph in phases]
    ipc_clean = [v if v is not None else float("nan") for v in ipc_vals]
    cache_clean = [v if v is not None else float("nan") for v in cache_vals]

    fig, ax1 = plt.subplots(figsize=(12, 5))
    ax2 = ax1.twinx()
    ax1.plot(x, ipc_clean, color="green", marker="o", label="IPC")
    ax2.plot(x, cache_clean, color="purple", marker="s", label="Cache Miss %", linestyle="--")
    ax1.set_xticks(list(x))
    ax1.set_xticklabels(xlabels, fontsize=8)
    ax1.set_ylabel("IPC", color="green")
    ax2.set_ylabel("Cache Miss Rate (%)", color="purple")
    ax1.set_title("gNB1 – IPC & Cache Miss Rate per Phase")
    fig.legend(loc="upper left", bbox_to_anchor=(0.08, 0.92))
    ax1.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig(os.path.join(plots_dir, "gnb1_ipc_cache_per_phase.png"), dpi=120)
    plt.close()

    # Plot 4: Context-switch rate gnb1
    nd_ctx = ctxsw.get("gnb1", {})
    ctxsw_vals = [nd_ctx.get(ph, {}).get("ctxsw_per_s") for ph in phases]
    ctxsw_clean = [v if v is not None else float("nan") for v in ctxsw_vals]

    fig, ax = plt.subplots(figsize=(12, 5))
    ax.fill_between(list(x), ctxsw_clean, alpha=0.4, color="teal")
    ax.plot(x, ctxsw_clean, color="teal", marker="D")
    ax.set_xticks(list(x))
    ax.set_xticklabels(xlabels, fontsize=8)
    ax.set_ylabel("Context Switches / s")
    ax.set_title("gNB1 – Context-Switch Rate per Phase")
    ax.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig(os.path.join(plots_dir, "gnb1_ctxsw_per_phase.png"), dpi=120)
    plt.close()

    print(f"[plots] Wrote 4 plots to {plots_dir}/")


# ──────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────

def main():
    args = parse_args()
    results_dir = args.results_dir
    out_dir = args.out_dir or results_dir
    os.makedirs(out_dir, exist_ok=True)

    print(f"[analyze] Reading results from {os.path.abspath(results_dir)}")

    # Run all analysis sections
    print("[analyze] Section 1/7  — Handover / LB latency")
    handover = analyze_handover(results_dir, args.verbose)

    print("[analyze] Section 2/7  — Power")
    power = analyze_power(results_dir, args.verbose)

    print("[analyze] Section 3/7  — gNB load vs nof_ue")
    gnb_load = analyze_gnb_load(results_dir, args.verbose)

    print("[analyze] Section 4/7  — Per-core CPU imbalance")
    cpu_imbal = analyze_cpu_imbalance(results_dir, args.verbose)

    print("[analyze] Section 5/7  — Context-switch rate")
    ctxsw = analyze_ctxsw(results_dir, args.verbose)

    print("[analyze] Section 6/7  — IPC / cache miss")
    ipc = analyze_ipc(results_dir, args.verbose)

    print("[analyze] Section 7/7  — Process + RAN metrics")
    proc = analyze_process(results_dir, args.verbose)
    ran  = analyze_ran_metrics(results_dir, args.verbose)

    # Build phase table CSV
    phase_rows = build_phase_table(power, gnb_load, ctxsw, ipc, proc)
    phase_csv_path = os.path.join(out_dir, "lb_analysis.csv")
    write_phase_csv(phase_rows, phase_csv_path)
    print(f"[analyze] Wrote phase table → {phase_csv_path}")

    # Write key findings text report
    write_key_findings(args, handover, power, gnb_load, cpu_imbal, ctxsw, ipc, proc, ran, out_dir)

    # Optional plots
    if args.plots:
        generate_plots(power, gnb_load, ipc, ctxsw, out_dir)

    # Print quick summary to stdout
    print("")
    print("=" * 60)
    print("  QUICK SUMMARY")
    print("=" * 60)
    print(f"  Handover latency:    {_line(handover['handover_duration_ms'], 'ms')}")
    print(f"  E2E LB latency:      {_line(handover['e2e_lb_latency_ms'], 'ms')}")
    print(f"  gNB1 power saved:    {_line(power.get('gnb1_power_saved_W'), 'W')}")
    print(f"  gNB2 marginal power: {_line(power.get('gnb2_marginal_power_W'), 'W')}")
    print(f"  Throughput drop:     {_line(handover['throughput_drop_pct'], '%')}")
    print(f"  Reports → {os.path.abspath(out_dir)}/")
    print("=" * 60)


if __name__ == "__main__":
    main()
