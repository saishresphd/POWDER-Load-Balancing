#!/usr/bin/env python3
"""
merge_ran_csv.py — POWDER Load-Balancing Experiment CSV Merger
===============================================================
Merges all per-node CSVs collected during the UE51 load-balancing experiment
into a single time-aligned master_dataset.csv suitable for CPU power-saving
algorithm design and analysis.

Input files (auto-discovered under --results-dir):
  system_metrics.csv        — CPU%, freq, mem, temp, IRQ, IPC, power, phase
  gnb_metrics.csv           — per-gNB UE count, DL/UL bitrate, sched usage
  gnb_rich_gnb1.csv         — 32-core CPU, PUSCH/PDSCH/PUCCH radio metrics (gNB1)
  gnb_rich_gnb2.csv         — same for gNB2
  power.csv                 — RAPL pkg/dram power, CPU freq (from collect_power.sh)
  deep_sysmon_gnb1.csv      — per-core + per-process schedstat, softirq (gNB1)
  deep_sysmon_gnb2.csv      — same for gNB2
  iperf_results_500.csv     — per-UE throughput at each ramp step, phase-labeled
  ue51_handover.csv         — ms-resolution handover timing, tun state, ICMP loss

Output: master_dataset.csv with columns from all sources, aligned on timestamp
(epoch seconds, 1s resolution), gap-filled, and phase-labeled.

Usage:
  python3 merge_ran_csv.py \\
      --results-dir /tmp/ran_collect/results \\
      --output master_dataset.csv \\
      [--resample 1s] \\
      [--fill ffill|zero|none] \\
      [--phase-file /tmp/ran_collect/phase.txt]
"""

import argparse
import os
import sys
import glob
import math
import warnings
from pathlib import Path

import pandas as pd
import numpy as np

warnings.filterwarnings("ignore", category=FutureWarning)
warnings.filterwarnings("ignore", category=pd.errors.PerformanceWarning)

# ---------------------------------------------------------------------------
# Column schemas — used to coerce dtypes and detect files
# ---------------------------------------------------------------------------

SCHEMA = {
    "system_metrics": {
        "file_pattern": "**/system_metrics.csv",
        "ts_col": "timestamp",        # epoch float seconds
        "phase_col": "phase",
        "numeric_cols": [
            "cpu_pct", "cpu_freq_mhz", "mem_used_mb", "mem_total_mb",
            "mem_free_mb", "mem_cache_mb", "load1", "load5", "load15",
            "num_cpus", "running_procs", "total_procs", "temp_c",
            "irq_rate", "ctxt_rate", "ipc", "rx_bytes_s", "tx_bytes_s",
            "srsenb_count", "srsue_count", "cpu_user_pct", "cpu_sys_pct",
            "cpu_iowait_pct", "cpu_steal_pct", "power_w",
        ],
        "str_cols": ["hostname"],
        "prefix": "sys",
    },
    "gnb_metrics": {
        "file_pattern": "**/gnb_metrics.csv",
        "ts_col": "timestamp",
        "phase_col": "phase",
        "numeric_cols": [
            "nof_ue", "dl_brate_mbps", "ul_brate_mbps",
            "dl_nof_ok", "dl_nof_nok", "ul_nof_ok", "ul_nof_nok",
            "dl_sched_usign", "ul_sched_usign", "phr", "last_ta", "sys_load",
        ],
        "str_cols": ["gnb_id", "ue_slot"],
        "prefix": "gnb",
    },
    "gnb_rich_gnb1": {
        "file_pattern": "**/gnb_rich_gnb1.csv",
        "ts_col": "timestamp",
        "phase_col": None,
        "numeric_cols": None,   # all remaining after str cols
        "str_cols": ["gnb_id"],
        "prefix": "rich_gnb1",
    },
    "gnb_rich_gnb2": {
        "file_pattern": "**/gnb_rich_gnb2.csv",
        "ts_col": "timestamp",
        "phase_col": None,
        "numeric_cols": None,
        "str_cols": ["gnb_id"],
        "prefix": "rich_gnb2",
    },
    "power": {
        "file_pattern": "**/power.csv",
        "ts_col": "timestamp",
        "phase_col": None,
        "numeric_cols": [
            "elapsed_s",
            "pkg0_power_W", "pkg1_power_W",
            "dram0_power_W", "dram1_power_W",
            "cpu0_freq_MHz", "cpu_max_freq_MHz",
        ],
        "str_cols": [],
        "prefix": "pwr",
    },
    "deep_sysmon_gnb1": {
        "file_pattern": "**/deep_sysmon_gnb1.csv",
        "ts_col": "timestamp",
        "phase_col": None,
        "numeric_cols": None,
        "str_cols": [],
        "prefix": "dsys_gnb1",
    },
    "deep_sysmon_gnb2": {
        "file_pattern": "**/deep_sysmon_gnb2.csv",
        "ts_col": "timestamp",
        "phase_col": None,
        "numeric_cols": None,
        "str_cols": [],
        "prefix": "dsys_gnb2",
    },
    "iperf_results_500": {
        "file_pattern": "**/iperf_results_500.csv",
        "ts_col": "timestamp",
        "phase_col": "phase",
        "numeric_cols": [
            "target_mbps", "actual_mbps", "bytes",
            "duration_s", "retransmits",
        ],
        "str_cols": ["ue_id", "direction"],
        "prefix": "iperf",
    },
    "ue51_handover": {
        "file_pattern": "**/ue51_handover.csv",
        "ts_col": "timestamp_s",    # epoch seconds (float, ms precision)
        "phase_col": "phase",
        "numeric_cols": [
            "elapsed_ms", "tun_up", "ping_rtt_ms", "ping_loss_pct",
            "dl_bytes", "dl_mbps", "rapl_power_w", "cpu_pct",
        ],
        "str_cols": ["event"],
        "prefix": "ho",
    },
}

# Key derived columns for CPU power-saving algorithm research
KEY_RESEARCH_COLS = [
    # Identity / phase
    "phase",
    # Load indicator
    "sys_cpu_pct", "sys_load1", "sys_load5",
    "sys_cpu_user_pct", "sys_sys_pct", "sys_iowait_pct",
    # Power
    "sys_power_w", "pwr_pkg0_power_W", "pwr_pkg1_power_W",
    "pwr_dram0_power_W", "pwr_dram1_power_W",
    # Frequency
    "sys_cpu_freq_mhz", "pwr_cpu0_freq_MHz", "pwr_cpu_max_freq_MHz",
    # Temperature
    "sys_temp_c",
    # Efficiency
    "sys_ipc",
    # Interrupt pressure
    "sys_irq_rate", "sys_ctxt_rate",
    # Network throughput
    "gnb_dl_brate_mbps", "gnb_ul_brate_mbps",
    "sys_rx_bytes_s", "sys_tx_bytes_s",
    # Radio scheduling efficiency
    "gnb_dl_sched_usign", "gnb_ul_sched_usign",
    # UE count (load proxy)
    "gnb_nof_ue",
    # Handover timing
    "ho_elapsed_ms", "ho_tun_up", "ho_ping_rtt_ms", "ho_ping_loss_pct",
    "ho_dl_mbps",
    # iperf aggregate throughput
    "iperf_actual_mbps",
]


def _to_epoch_seconds(series: pd.Series) -> pd.Series:
    """
    Convert a timestamp column to epoch float seconds.
    Handles: epoch int/float (ms or s), ISO string.
    """
    s = series.copy()
    # Try numeric first
    numeric = pd.to_numeric(s, errors="coerce")
    if numeric.notna().mean() > 0.8:
        # Detect milliseconds: values > 1e12 are almost certainly ms
        if numeric.dropna().median() > 1e12:
            numeric = numeric / 1000.0
        return numeric
    # Try datetime string
    dt = pd.to_datetime(s, errors="coerce", utc=True)
    if dt.notna().mean() > 0.8:
        return dt.astype(np.int64) / 1e9
    return numeric  # best effort


def _load_csv(path: str, schema: dict, prefix: str) -> pd.DataFrame | None:
    """Load one CSV, normalise timestamp, prefix non-ts columns."""
    try:
        df = pd.read_csv(path, low_memory=False)
    except Exception as e:
        print(f"  [WARN] Could not read {path}: {e}", file=sys.stderr)
        return None

    if df.empty:
        print(f"  [WARN] Empty file: {path}", file=sys.stderr)
        return None

    ts_col = schema["ts_col"]
    if ts_col not in df.columns:
        # Try alternate common names
        for alt in ("timestamp", "time", "ts", "epoch", "timestamp_s", "time_s"):
            if alt in df.columns:
                ts_col = alt
                break
        else:
            print(f"  [WARN] No timestamp column in {path}", file=sys.stderr)
            return None

    df["_ts_epoch"] = _to_epoch_seconds(df[ts_col])
    df = df.dropna(subset=["_ts_epoch"])
    df["_ts_epoch"] = df["_ts_epoch"].round(3)  # ms precision

    # Coerce numeric columns
    if schema["numeric_cols"] is not None:
        for c in schema["numeric_cols"]:
            if c in df.columns:
                df[c] = pd.to_numeric(df[c], errors="coerce")
    else:
        # Coerce all non-string columns
        str_cols = set(schema.get("str_cols", []) + [ts_col, "_ts_epoch"])
        phase_col = schema.get("phase_col")
        if phase_col:
            str_cols.add(phase_col)
        for c in df.columns:
            if c not in str_cols:
                df[c] = pd.to_numeric(df[c], errors="coerce")

    # Rename all data columns with prefix (skip _ts_epoch and phase)
    phase_col = schema.get("phase_col")
    rename_map = {}
    for c in df.columns:
        if c in ("_ts_epoch", phase_col):
            continue
        if c == ts_col:
            continue
        rename_map[c] = f"{prefix}_{c}"

    df = df.rename(columns=rename_map)

    # Keep phase as canonical "phase" (take first occurrence)
    if phase_col and phase_col in df.columns:
        df = df.rename(columns={phase_col: "phase"})

    print(f"  [OK] {Path(path).name}: {len(df)} rows, {len(df.columns)} cols")
    return df


def _aggregate_to_1s(df: pd.DataFrame, fill: str) -> pd.DataFrame:
    """
    Resample a dataframe to 1-second bins aligned to integer epoch seconds.
    Numeric columns: mean. String/phase columns: last value.
    """
    df = df.copy()
    df["_ts_1s"] = df["_ts_epoch"].apply(math.floor).astype(np.int64)

    str_cols = df.select_dtypes(include="object").columns.tolist()
    num_cols = df.select_dtypes(include=[np.number]).columns.tolist()
    # Remove internal cols from aggregation inputs
    for c in ("_ts_epoch", "_ts_1s"):
        if c in num_cols:
            num_cols.remove(c)

    agg_dict = {c: "mean" for c in num_cols}
    agg_dict.update({c: "last" for c in str_cols})

    grouped = df.groupby("_ts_1s").agg(agg_dict).reset_index()
    grouped = grouped.rename(columns={"_ts_1s": "timestamp_epoch"})
    return grouped


def _fill_gaps(df: pd.DataFrame, fill: str) -> pd.DataFrame:
    if fill == "ffill":
        # Forward-fill only string/phase columns; leave numeric NaN for analysis
        str_cols = df.select_dtypes(include="object").columns.tolist()
        if "phase" in str_cols:
            df["phase"] = df["phase"].ffill()
    elif fill == "zero":
        num_cols = df.select_dtypes(include=[np.number]).columns.tolist()
        df[num_cols] = df[num_cols].fillna(0)
    # fill == "none": leave NaN
    return df


def _inject_phase_from_file(df: pd.DataFrame, phase_file: str | None) -> pd.DataFrame:
    """
    If phase column is still missing or all-NaN, try to infer from a phase log file.
    Phase log format (from orchestrate_collection.sh set_phase()):
      <epoch_seconds> <phase_label>
    """
    if "phase" in df.columns and df["phase"].notna().any():
        return df  # already have phase

    if not phase_file or not os.path.exists(phase_file):
        return df

    try:
        phase_log = pd.read_csv(
            phase_file, sep=r"\s+", header=None, names=["ts", "phase_label"]
        )
        phase_log["ts"] = pd.to_numeric(phase_log["ts"], errors="coerce")
        phase_log = phase_log.dropna().sort_values("ts")
    except Exception:
        return df

    # Build a series: for each row in df, find the most recent phase entry
    df = df.sort_values("timestamp_epoch")
    phases = []
    phase_ts = phase_log["ts"].values
    phase_labels = phase_log["phase_label"].values
    for row_ts in df["timestamp_epoch"].values:
        idx = np.searchsorted(phase_ts, row_ts, side="right") - 1
        if idx >= 0:
            phases.append(phase_labels[idx])
        else:
            phases.append("unknown")
    df["phase"] = phases
    return df


def _add_derived_columns(df: pd.DataFrame) -> pd.DataFrame:
    """Add computed columns useful for CPU power-saving algorithm research."""

    # Total RAPL socket power (pkg0 + pkg1) — best single power proxy
    if "pwr_pkg0_power_W" in df.columns and "pwr_pkg1_power_W" in df.columns:
        df["total_socket_power_W"] = df["pwr_pkg0_power_W"].fillna(0) + df["pwr_pkg1_power_W"].fillna(0)

    # Total DRAM power
    if "pwr_dram0_power_W" in df.columns and "pwr_dram1_power_W" in df.columns:
        df["total_dram_power_W"] = df["pwr_dram0_power_W"].fillna(0) + df["pwr_dram1_power_W"].fillna(0)

    # Total platform power
    if "total_socket_power_W" in df.columns and "total_dram_power_W" in df.columns:
        df["total_platform_power_W"] = df["total_socket_power_W"] + df["total_dram_power_W"]

    # Power efficiency: throughput / power (Mbps per Watt)
    if "gnb_dl_brate_mbps" in df.columns and "total_socket_power_W" in df.columns:
        denom = df["total_socket_power_W"].replace(0, np.nan)
        df["power_efficiency_mbps_per_W"] = df["gnb_dl_brate_mbps"] / denom

    # UE attachment delta (change in nof_ue per second — LB event detector)
    if "gnb_nof_ue" in df.columns:
        df["gnb_nof_ue_delta"] = df["gnb_nof_ue"].diff().fillna(0)

    # Handover in-progress flag: 1 during lb_transition phase
    if "phase" in df.columns:
        df["lb_in_progress"] = (
            df["phase"].str.contains("lb_trigger|transition|gnb2", na=False)
        ).astype(int)

    # CPU load factor: cpu_pct / num_cpus (normalized 0–1)
    if "sys_cpu_pct" in df.columns and "sys_num_cpus" in df.columns:
        df["cpu_load_factor"] = df["sys_cpu_pct"] / (df["sys_num_cpus"].replace(0, np.nan) * 100)

    return df


def _print_summary(df: pd.DataFrame, output: str) -> None:
    print("\n" + "=" * 60)
    print("MASTER DATASET SUMMARY")
    print("=" * 60)
    print(f"  Output file  : {output}")
    print(f"  Rows         : {len(df):,}")
    print(f"  Columns      : {len(df.columns)}")
    if "timestamp_epoch" in df.columns:
        span = df["timestamp_epoch"].max() - df["timestamp_epoch"].min()
        print(f"  Time span    : {span:.1f} seconds ({span/60:.1f} minutes)")
    if "phase" in df.columns:
        print(f"  Phases found : {sorted(df['phase'].dropna().unique().tolist())}")

    # Key research column coverage
    present = [c for c in KEY_RESEARCH_COLS if c in df.columns]
    missing = [c for c in KEY_RESEARCH_COLS if c not in df.columns]
    print(f"\n  Key research columns present ({len(present)}/{len(KEY_RESEARCH_COLS)}):")
    for c in present:
        non_null = df[c].notna().sum()
        print(f"    ✓ {c:<45s} {non_null:>6} non-null rows")
    if missing:
        print(f"\n  Key research columns MISSING ({len(missing)}):")
        for c in missing:
            print(f"    ✗ {c}")
    print("=" * 60)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--results-dir", default="/tmp/ran_collect/results",
                    help="Root directory containing per-node CSV files")
    ap.add_argument("--output", default="master_dataset.csv",
                    help="Output CSV path")
    ap.add_argument("--resample", default="1s",
                    help="Resample resolution (default: 1s)")
    ap.add_argument("--fill", choices=["ffill", "zero", "none"], default="ffill",
                    help="Gap-fill strategy: ffill=forward-fill phase only, "
                         "zero=fill numeric with 0, none=leave NaN")
    ap.add_argument("--phase-file", default=None,
                    help="Optional path to phase log file for phase injection")
    args = ap.parse_args()

    results_dir = Path(args.results_dir)
    if not results_dir.exists():
        # Fallback: try one level up (direct /tmp/ran_collect/)
        fallback = results_dir.parent
        if fallback.exists():
            results_dir = fallback
            print(f"[INFO] results-dir not found, using fallback: {results_dir}")
        else:
            print(f"[ERROR] results-dir not found: {results_dir}", file=sys.stderr)
            sys.exit(1)

    print(f"[INFO] Scanning: {results_dir}")

    # -----------------------------------------------------------------------
    # Load all source CSVs
    # -----------------------------------------------------------------------
    frames: list[pd.DataFrame] = []

    for source_name, schema in SCHEMA.items():
        pattern = str(results_dir / schema["file_pattern"].lstrip("**/"))
        # Also search recursively
        matches = glob.glob(str(results_dir / "**" / Path(schema["file_pattern"]).name),
                            recursive=True)
        # Also check direct path
        direct = results_dir / Path(schema["file_pattern"]).name
        if direct.exists():
            matches.append(str(direct))
        matches = sorted(set(matches))

        if not matches:
            print(f"  [SKIP] {source_name}: no files found ({schema['file_pattern']})")
            continue

        print(f"\n[Loading] {source_name} ({len(matches)} file(s)):")
        source_frames = []
        for path in matches:
            df = _load_csv(path, schema, schema["prefix"])
            if df is not None:
                df["_source"] = source_name
                source_frames.append(df)

        if not source_frames:
            continue

        # Concatenate multiple files for same source (e.g. multi-node system_metrics)
        combined = pd.concat(source_frames, ignore_index=True, sort=False)
        # Aggregate to 1-second bins
        combined_1s = _aggregate_to_1s(combined, args.fill)
        frames.append(combined_1s)

    if not frames:
        print("[ERROR] No data loaded — check --results-dir path", file=sys.stderr)
        sys.exit(1)

    # -----------------------------------------------------------------------
    # Merge all frames on 1-second epoch timestamp
    # -----------------------------------------------------------------------
    print(f"\n[Merging] {len(frames)} source(s) on timestamp_epoch...")

    # Sort each frame by timestamp first
    for i, df in enumerate(frames):
        frames[i] = df.sort_values("timestamp_epoch")

    # Outer join so no data is lost; use merge_asof for nearest-second alignment
    master = frames[0]
    for df in frames[1:]:
        # Identify phase column conflicts
        if "phase" in master.columns and "phase" in df.columns:
            df = df.rename(columns={"phase": "phase_alt"})

        master = pd.merge_asof(
            master.sort_values("timestamp_epoch"),
            df.sort_values("timestamp_epoch"),
            on="timestamp_epoch",
            tolerance=2,          # ±2 second tolerance
            direction="nearest",
        )

        # Reconcile phase columns
        if "phase_alt" in master.columns:
            master["phase"] = master["phase"].fillna(master["phase_alt"])
            master = master.drop(columns=["phase_alt"])

    # -----------------------------------------------------------------------
    # Post-processing
    # -----------------------------------------------------------------------
    master = _inject_phase_from_file(master, args.phase_file)
    master = _fill_gaps(master, args.fill)
    master = _add_derived_columns(master)

    # Remove pure-internal columns
    internal = [c for c in master.columns if c.startswith("_")]
    master = master.drop(columns=internal, errors="ignore")

    # Sort by time
    master = master.sort_values("timestamp_epoch").reset_index(drop=True)

    # -----------------------------------------------------------------------
    # Write output
    # -----------------------------------------------------------------------
    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    master.to_csv(str(out_path), index=False)

    _print_summary(master, str(out_path))

    # Also write a key-columns-only subset for quick analysis
    key_cols_present = ["timestamp_epoch"] + [c for c in KEY_RESEARCH_COLS if c in master.columns]
    key_df = master[key_cols_present]
    key_out = out_path.parent / (out_path.stem + "_key_cols.csv")
    key_df.to_csv(str(key_out), index=False)
    print(f"\n[INFO] Key-columns subset: {key_out} ({len(key_df.columns)} cols)")
    print("[DONE]")


if __name__ == "__main__":
    main()
