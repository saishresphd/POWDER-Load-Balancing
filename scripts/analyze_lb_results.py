#!/usr/bin/env python3
"""
analyze_lb_results.py — Post-experiment phase analysis for LB study
Reads all CSVs from --results-dir, computes per-phase aggregates, writes
key_findings.txt and lb_analysis.csv for CPU power-saving algorithm design.

Usage:
  python3 analyze_lb_results.py \\
      --results-dir /tmp/ran_collect \\
      --out /tmp/ran_collect/results/key_findings.txt \\
      --csv /tmp/ran_collect/results/lb_analysis.csv \\
      [--plots]
"""

import argparse
import os
import sys
import csv
import json
import math
from pathlib import Path
from collections import defaultdict
from datetime import datetime

# Optional matplotlib
try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    HAS_PLOT = True
except ImportError:
    HAS_PLOT = False


# ─────────────────────────────────────────────
# CSV loading helpers
# ─────────────────────────────────────────────

def load_csv(path):
    """Return list of dicts from a CSV file; skip empty / bad rows."""
    rows = []
    try:
        with open(path, newline="") as f:
            reader = csv.DictReader(f)
            for row in reader:
                if any(v.strip() for v in row.values()):
                    rows.append(row)
    except Exception as e:
        print(f"[WARN] Could not read {path}: {e}", file=sys.stderr)
    return rows


def safe_float(val, default=0.0):
    try:
        return float(str(val).strip())
    except (ValueError, TypeError):
        return default


# ─────────────────────────────────────────────
# Phase classification
# ─────────────────────────────────────────────

PHASE_ORDER = [
    "baseline_50ue",
    "pre_lb_51ue",
    "lb_transition",
    "post_lb",
    "unknown",
]


def classify_phase(phase_str):
    """Normalize raw phase label → canonical phase bucket."""
    p = str(phase_str).lower().strip()
    if "baseline" in p or "50ue" in p:
        return "baseline_50ue"
    if "pre" in p or "51ue" in p:
        return "pre_lb_51ue"
    if "transition" in p or "handover" in p or "lb_" in p:
        return "lb_transition"
    if "post" in p or "after" in p:
        return "post_lb"
    return "unknown"


# ─────────────────────────────────────────────
# Metric extraction per source file
# ─────────────────────────────────────────────

def parse_system_metrics(rows):
    """system_metrics.csv → per-phase cpu_pct, mem_pct, rx_mbps, tx_mbps."""
    buckets = defaultdict(list)
    for r in rows:
        phase = classify_phase(r.get("phase", "unknown"))
        buckets[phase].append({
            "cpu": safe_float(r.get("cpu_pct", r.get("cpu", 0))),
            "mem": safe_float(r.get("mem_pct", r.get("mem", 0))),
            "rx":  safe_float(r.get("rx_mbps", r.get("rx", 0))),
            "tx":  safe_float(r.get("tx_mbps", r.get("tx", 0))),
        })
    return buckets


def parse_power(rows):
    """power.csv → per-phase pkg_watts, dram_watts."""
    buckets = defaultdict(list)
    for r in rows:
        phase = classify_phase(r.get("phase", "unknown"))
        buckets[phase].append({
            "pkg":  safe_float(r.get("pkg_watts", r.get("pkg", 0))),
            "dram": safe_float(r.get("dram_watts", r.get("dram", 0))),
        })
    return buckets


def parse_perf_ipc(rows):
    """perf_ipc*.csv → per-phase IPC, instructions, cycles (cpu=all rows only)."""
    buckets = defaultdict(list)
    for r in rows:
        if str(r.get("cpu", "")).strip() not in ("all", ""):
            continue
        phase = classify_phase(r.get("phase", "unknown"))
        ipc = safe_float(r.get("ipc", 0))
        if ipc > 0:
            buckets[phase].append({
                "ipc":   ipc,
                "instr": safe_float(r.get("instructions", 0)),
                "cycles": safe_float(r.get("cycles", 0)),
            })
    return buckets


def parse_gnb_metrics(rows):
    """gnb_metrics.csv / gnb_rich_gnb1.csv → per-phase dl_tput_mbps, dl_bler, n_ues."""
    buckets = defaultdict(list)
    for r in rows:
        phase = classify_phase(r.get("phase", "unknown"))
        buckets[phase].append({
            "tput": safe_float(r.get("dl_tput_mbps", r.get("dl_tput", r.get("tput_mbps", 0)))),
            "bler": safe_float(r.get("dl_bler", r.get("bler", 0))),
            "n_ues": safe_float(r.get("n_ues", r.get("num_ues", 0))),
        })
    return buckets


def parse_handover(rows):
    """ue51_handover.csv → handover_duration_ms and disconnected timestamp."""
    events = []
    for r in rows:
        state = str(r.get("state", r.get("status", ""))).lower()
        ts    = safe_float(r.get("timestamp_ms", r.get("ts_ms", 0)))
        events.append({"state": state, "ts_ms": ts})
    if not events:
        return None
    # Find disconnect→reconnect window
    disc_ts = next((e["ts_ms"] for e in events if "disc" in e["state"]), None)
    conn_ts = next((e["ts_ms"] for e in events if "conn" in e["state"] and e["ts_ms"] > (disc_ts or 0)), None)
    if disc_ts and conn_ts:
        return {"disconnect_ms": disc_ts, "reconnect_ms": conn_ts,
                "handover_duration_ms": conn_ts - disc_ts}
    return None


def parse_iperf(rows):
    """iperf_results_500.csv → per-phase avg/min/max throughput."""
    buckets = defaultdict(list)
    for r in rows:
        phase = classify_phase(r.get("phase", "unknown"))
        tput  = safe_float(r.get("tput_mbps", r.get("throughput_mbps", r.get("bitrate_mbps", 0))))
        if tput > 0:
            buckets[phase].append(tput)
    return buckets


# ─────────────────────────────────────────────
# Statistical helpers
# ─────────────────────────────────────────────

def stats(values):
    if not values:
        return {"mean": 0.0, "min": 0.0, "max": 0.0, "std": 0.0, "n": 0}
    n = len(values)
    mean = sum(values) / n
    variance = sum((x - mean) ** 2 for x in values) / n if n > 1 else 0
    return {
        "mean": round(mean, 4),
        "min":  round(min(values), 4),
        "max":  round(max(values), 4),
        "std":  round(math.sqrt(variance), 4),
        "n":    n,
    }


# ─────────────────────────────────────────────
# Phase aggregation
# ─────────────────────────────────────────────

def aggregate_phases(results_dir: Path):
    """Load all CSVs and return a dict of phase → aggregated metrics."""
    # Discover files
    sys_files   = list(results_dir.glob("**/system_metrics*.csv"))
    power_files = list(results_dir.glob("**/power*.csv"))
    ipc_files   = list(results_dir.glob("**/perf_ipc*.csv"))
    gnb_files   = list(results_dir.glob("**/gnb_metrics*.csv")) + \
                  list(results_dir.glob("**/gnb_rich*.csv"))
    ho_files    = list(results_dir.glob("**/ue51_handover*.csv"))
    iperf_files = list(results_dir.glob("**/iperf_results*.csv"))

    def load_all(paths):
        rows = []
        for p in paths:
            rows.extend(load_csv(p))
        return rows

    sys_rows   = load_all(sys_files)
    pwr_rows   = load_all(power_files)
    ipc_rows   = load_all(ipc_files)
    gnb_rows   = load_all(gnb_files)
    ho_rows    = load_all(ho_files)
    iperf_rows = load_all(iperf_files)

    sys_buckets   = parse_system_metrics(sys_rows)
    pwr_buckets   = parse_power(pwr_rows)
    ipc_buckets   = parse_perf_ipc(ipc_rows)
    gnb_buckets   = parse_gnb_metrics(gnb_rows)
    iperf_buckets = parse_iperf(iperf_rows)
    handover_info = parse_handover(ho_rows)

    all_phases = set(
        list(sys_buckets) + list(pwr_buckets) + list(ipc_buckets) +
        list(gnb_buckets) + list(iperf_buckets) + ["baseline_50ue", "pre_lb_51ue",
                                                    "lb_transition", "post_lb"]
    )

    phase_data = {}
    for phase in all_phases:
        sys_v   = sys_buckets.get(phase, [])
        pwr_v   = pwr_buckets.get(phase, [])
        ipc_v   = ipc_buckets.get(phase, [])
        gnb_v   = gnb_buckets.get(phase, [])
        iperf_v = iperf_buckets.get(phase, [])

        phase_data[phase] = {
            "cpu_pct":     stats([r["cpu"] for r in sys_v]),
            "mem_pct":     stats([r["mem"] for r in sys_v]),
            "rx_mbps":     stats([r["rx"]  for r in sys_v]),
            "pkg_watts":   stats([r["pkg"] for r in pwr_v]),
            "dram_watts":  stats([r["dram"] for r in pwr_v]),
            "ipc":         stats([r["ipc"] for r in ipc_v]),
            "dl_tput_mbps": stats([r["tput"] for r in gnb_v]),
            "dl_bler":     stats([r["bler"] for r in gnb_v]),
            "n_ues":       stats([r["n_ues"] for r in gnb_v]),
            "iperf_mbps":  stats(iperf_v),
        }

    return phase_data, handover_info


# ─────────────────────────────────────────────
# Key findings generator
# ─────────────────────────────────────────────

def generate_findings(phase_data, handover_info, results_dir):
    lines = []
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    lines += [
        "=" * 70,
        " POWDER LOAD-BALANCING EXPERIMENT — KEY RESEARCH FINDINGS",
        f" Generated: {ts}",
        "=" * 70,
        "",
        "PURPOSE: Data to inform CPU power-saving algorithm design for",
        "         O-RAN / srsRAN gNB under varying UE load and LB events.",
        "",
    ]

    # ── Handover timing ──
    lines.append("─" * 60)
    lines.append("SECTION 1: HANDOVER / LOAD-BALANCE TIMING")
    lines.append("─" * 60)
    if handover_info:
        dur = handover_info.get("handover_duration_ms", 0)
        lines.append(f"  Handover Duration      : {dur:.1f} ms")
        lines.append(f"  Disconnect timestamp   : {handover_info.get('disconnect_ms',0):.0f} ms (epoch)")
        lines.append(f"  Reconnect timestamp    : {handover_info.get('reconnect_ms',0):.0f} ms (epoch)")
        lines.append("")
        lines.append("  KEY FINDING: Handover creates a dead-zone window where UE51")
        lines.append(f"  experiences {dur:.0f} ms of service interruption.")
        lines.append("  Algorithm implication: Power-save mode should NOT activate")
        lines.append("  during active handover (transition state recognition needed).")
    else:
        lines.append("  No handover timing data found in ue51_handover*.csv")
        lines.append("  Check /tmp/ran_collect/ on uehost2 for the file.")
    lines.append("")

    # ── Per-phase metrics ──
    for phase in PHASE_ORDER:
        d = phase_data.get(phase)
        if d is None:
            continue

        lines.append("─" * 60)
        lines.append(f"PHASE: {phase.upper()}")
        lines.append("─" * 60)

        cpu = d["cpu_pct"]
        pkg = d["pkg_watts"]
        ipc = d["ipc"]
        tput = d["iperf_mbps"] if d["iperf_mbps"]["n"] > 0 else d["dl_tput_mbps"]
        n_ues = d["n_ues"]

        def fmt(s, unit=""):
            if s["n"] == 0:
                return "  (no data)"
            return (f"  mean={s['mean']:.3f}{unit}  "
                    f"min={s['min']:.3f}{unit}  "
                    f"max={s['max']:.3f}{unit}  "
                    f"std={s['std']:.3f}  n={s['n']}")

        lines.append(f"  UE count (avg)         : {n_ues['mean']:.1f}")
        lines.append(f"  CPU utilization (%)")
        lines.append(fmt(cpu, "%"))
        lines.append(f"  RAPL pkg power (W)")
        lines.append(fmt(pkg, " W"))
        lines.append(f"  DRAM power (W)")
        lines.append(fmt(d["dram_watts"], " W"))
        lines.append(f"  IPC (instructions/cycle)")
        lines.append(fmt(ipc))
        lines.append(f"  Throughput (Mbps)")
        lines.append(fmt(tput, " Mbps"))
        lines.append(f"  DL BLER")
        lines.append(fmt(d["dl_bler"]))
        lines.append("")

    # ── Comparative deltas ──
    lines.append("─" * 60)
    lines.append("SECTION 2: DELTA ANALYSIS (Algorithm Design Inputs)")
    lines.append("─" * 60)

    def delta(a_phase, b_phase, metric, field="mean", unit=""):
        a = phase_data.get(a_phase, {}).get(metric, {}).get(field, None)
        b = phase_data.get(b_phase, {}).get(metric, {}).get(field, None)
        if a is None or b is None or (a == 0 and b == 0):
            return f"  {a_phase} → {b_phase} [{metric}]: insufficient data"
        d_abs = b - a
        d_pct = 100 * d_abs / a if a != 0 else 0
        return (f"  {a_phase} → {b_phase} [{metric}]: "
                f"{a:.3f}{unit} → {b:.3f}{unit}  "
                f"Δ={d_abs:+.3f}{unit} ({d_pct:+.1f}%)")

    # UE addition effect (50→51 UE)
    lines.append("\n[A] Effect of adding UE51 to gNB1 (50-UE baseline → 51-UE pre-LB)")
    lines.append(delta("baseline_50ue", "pre_lb_51ue", "cpu_pct", unit="%"))
    lines.append(delta("baseline_50ue", "pre_lb_51ue", "pkg_watts", unit=" W"))
    lines.append(delta("baseline_50ue", "pre_lb_51ue", "ipc"))
    lines.append(delta("baseline_50ue", "pre_lb_51ue", "iperf_mbps", unit=" Mbps"))

    # LB transition effect
    lines.append("\n[B] LB transition stress (pre-LB → transition)")
    lines.append(delta("pre_lb_51ue", "lb_transition", "cpu_pct", unit="%"))
    lines.append(delta("pre_lb_51ue", "lb_transition", "pkg_watts", unit=" W"))
    lines.append(delta("pre_lb_51ue", "lb_transition", "ipc"))
    lines.append(delta("pre_lb_51ue", "lb_transition", "dl_bler"))

    # Post-LB recovery
    lines.append("\n[C] Post-LB recovery (transition → post-LB)")
    lines.append(delta("lb_transition", "post_lb", "cpu_pct", unit="%"))
    lines.append(delta("lb_transition", "post_lb", "pkg_watts", unit=" W"))
    lines.append(delta("lb_transition", "post_lb", "iperf_mbps", unit=" Mbps"))

    # Power-per-Mbps efficiency
    lines.append("\n[D] Power efficiency (W per Mbps) per phase")
    for phase in ["baseline_50ue", "pre_lb_51ue", "post_lb"]:
        d = phase_data.get(phase, {})
        pwr  = d.get("pkg_watts", {}).get("mean", 0)
        tput_val = d.get("iperf_mbps", {})
        if tput_val.get("n", 0) == 0:
            tput_val = d.get("dl_tput_mbps", {})
        tput_mean = tput_val.get("mean", 0)
        if pwr > 0 and tput_mean > 0:
            eff = pwr / tput_mean
            lines.append(f"  {phase}: {pwr:.2f} W / {tput_mean:.1f} Mbps = {eff:.4f} W/Mbps")
        else:
            lines.append(f"  {phase}: insufficient data for efficiency calc")

    lines += [
        "",
        "─" * 60,
        "SECTION 3: ALGORITHM DESIGN RECOMMENDATIONS",
        "─" * 60,
        "",
        "1. TRIGGER THRESHOLD: Use CPU% + RAPL power jointly as LB trigger.",
        "   Single-metric triggers miss correlated IPC degradation.",
        "",
        "2. HANDOVER GUARD BAND: Suppress power-save transitions during",
        "   lb_transition phase (detected via UE count drop on gNB1).",
        "",
        "3. POST-LB COOLDOWN: Allow ~5s cooldown after UE count stabilizes",
        "   before activating deep power-save (DVFS downclock).",
        "",
        "4. IPC AS EFFICIENCY SIGNAL: Low IPC + high CPU% = memory-bound",
        "   scheduling bottleneck. High IPC + low CPU% = headroom for LB.",
        "",
        "5. POWER-PER-MBPS TARGET: Use W/Mbps efficiency metric from",
        "   Section 2D as objective function for adaptive power management.",
        "",
        "─" * 60,
        "DATA FILES ANALYSED",
        "─" * 60,
    ]

    # List files found
    for pattern in ["system_metrics", "power", "perf_ipc", "gnb_metrics",
                    "gnb_rich", "ue51_handover", "iperf_results"]:
        found = list(Path(results_dir).glob(f"**/*{pattern}*.csv"))
        lines.append(f"  {pattern:20s}: {len(found)} file(s)")

    lines += ["", "=" * 70, "END OF REPORT", "=" * 70]
    return "\n".join(lines)


# ─────────────────────────────────────────────
# CSV summary writer
# ─────────────────────────────────────────────

def write_csv_summary(phase_data, handover_info, out_path):
    fieldnames = [
        "phase",
        "cpu_pct_mean", "cpu_pct_std",
        "pkg_watts_mean", "pkg_watts_std",
        "dram_watts_mean",
        "ipc_mean", "ipc_std",
        "iperf_mbps_mean", "iperf_mbps_std",
        "dl_tput_mbps_mean",
        "dl_bler_mean",
        "n_ues_mean",
        "w_per_mbps",
        "handover_duration_ms",
    ]

    ho_dur = handover_info.get("handover_duration_ms", "") if handover_info else ""

    with open(out_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for phase in PHASE_ORDER:
            d = phase_data.get(phase)
            if d is None:
                continue
            pwr = d["pkg_watts"]["mean"]
            tput_v = d["iperf_mbps"] if d["iperf_mbps"]["n"] > 0 else d["dl_tput_mbps"]
            tput_m = tput_v["mean"]
            w_per_mbps = round(pwr / tput_m, 5) if tput_m > 0 else ""
            writer.writerow({
                "phase":             phase,
                "cpu_pct_mean":      d["cpu_pct"]["mean"],
                "cpu_pct_std":       d["cpu_pct"]["std"],
                "pkg_watts_mean":    d["pkg_watts"]["mean"],
                "pkg_watts_std":     d["pkg_watts"]["std"],
                "dram_watts_mean":   d["dram_watts"]["mean"],
                "ipc_mean":          d["ipc"]["mean"],
                "ipc_std":           d["ipc"]["std"],
                "iperf_mbps_mean":   d["iperf_mbps"]["mean"],
                "iperf_mbps_std":    d["iperf_mbps"]["std"],
                "dl_tput_mbps_mean": d["dl_tput_mbps"]["mean"],
                "dl_bler_mean":      d["dl_bler"]["mean"],
                "n_ues_mean":        d["n_ues"]["mean"],
                "w_per_mbps":        w_per_mbps,
                "handover_duration_ms": ho_dur if phase == "lb_transition" else "",
            })


# ─────────────────────────────────────────────
# Optional plots
# ─────────────────────────────────────────────

def generate_plots(phase_data, plots_dir: Path):
    if not HAS_PLOT:
        print("[WARN] matplotlib not available — skipping plots", file=sys.stderr)
        return
    plots_dir.mkdir(parents=True, exist_ok=True)

    phases = [p for p in PHASE_ORDER if p in phase_data]
    x = range(len(phases))

    def bar_plot(metric_key, field, ylabel, title, fname, color="steelblue"):
        vals = [phase_data[p].get(metric_key, {}).get(field, 0) for p in phases]
        errs = [phase_data[p].get(metric_key, {}).get("std", 0) for p in phases]
        fig, ax = plt.subplots(figsize=(8, 4))
        ax.bar(x, vals, yerr=errs, color=color, capsize=4, width=0.5)
        ax.set_xticks(list(x))
        ax.set_xticklabels(phases, rotation=15, ha="right", fontsize=9)
        ax.set_ylabel(ylabel)
        ax.set_title(title)
        ax.grid(axis="y", alpha=0.4)
        plt.tight_layout()
        plt.savefig(plots_dir / fname, dpi=150)
        plt.close()
        print(f"[plot] Saved {fname}")

    bar_plot("cpu_pct",    "mean", "CPU (%)",   "CPU Utilisation per Phase",  "cpu_per_phase.png")
    bar_plot("pkg_watts",  "mean", "Power (W)", "RAPL pkg Power per Phase",   "power_per_phase.png", "darkorange")
    bar_plot("ipc",        "mean", "IPC",        "IPC per Phase",              "ipc_per_phase.png",   "seagreen")
    bar_plot("iperf_mbps", "mean", "Mbps",       "Throughput per Phase",       "tput_per_phase.png",  "royalblue")

    # W/Mbps efficiency bar
    eff_vals = []
    for p in phases:
        d = phase_data[p]
        pwr = d["pkg_watts"]["mean"]
        tput = d["iperf_mbps"]["mean"] if d["iperf_mbps"]["n"] > 0 else d["dl_tput_mbps"]["mean"]
        eff_vals.append(pwr / tput if tput > 0 else 0)
    fig, ax = plt.subplots(figsize=(8, 4))
    ax.bar(list(x), eff_vals, color="crimson", width=0.5)
    ax.set_xticks(list(x))
    ax.set_xticklabels(phases, rotation=15, ha="right", fontsize=9)
    ax.set_ylabel("W / Mbps")
    ax.set_title("Power Efficiency (W per Mbps) per Phase")
    ax.grid(axis="y", alpha=0.4)
    plt.tight_layout()
    plt.savefig(plots_dir / "efficiency_per_phase.png", dpi=150)
    plt.close()
    print("[plot] Saved efficiency_per_phase.png")


# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--results-dir", default="/tmp/ran_collect",
                        help="Root directory containing all collected CSVs")
    parser.add_argument("--out", default="/tmp/ran_collect/results/key_findings.txt",
                        help="Output path for human-readable key findings")
    parser.add_argument("--csv", default="/tmp/ran_collect/results/lb_analysis.csv",
                        help="Output path for per-phase metrics CSV")
    parser.add_argument("--plots", action="store_true",
                        help="Generate bar charts (requires matplotlib)")
    args = parser.parse_args()

    results_dir = Path(args.results_dir)
    out_path    = Path(args.out)
    csv_path    = Path(args.csv)

    out_path.parent.mkdir(parents=True, exist_ok=True)

    print(f"[analyze_lb_results] Scanning {results_dir} ...")
    phase_data, handover_info = aggregate_phases(results_dir)

    print(f"[analyze_lb_results] Phases found: {sorted(phase_data.keys())}")

    # Key findings
    findings = generate_findings(phase_data, handover_info, results_dir)
    out_path.write_text(findings)
    print(f"[analyze_lb_results] Key findings → {out_path}")

    # CSV summary
    write_csv_summary(phase_data, handover_info, csv_path)
    print(f"[analyze_lb_results] Phase CSV    → {csv_path}")

    # Plots
    if args.plots:
        plots_dir = csv_path.parent / "plots"
        generate_plots(phase_data, plots_dir)
        print(f"[analyze_lb_results] Plots        → {plots_dir}/")

    # Print findings to stdout for quick review
    print("\n" + findings)


if __name__ == "__main__":
    main()
