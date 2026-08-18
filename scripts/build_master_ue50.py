#!/usr/bin/env python3
"""
build_master_ue50.py
====================
Aggregate all UE50 experiment data into a single master_ue50.csv
suitable for training a CPU power-saving / load-balancing algorithm.

Usage:
    python3 scripts/build_master_ue50.py <results_dir>
    python3 scripts/build_master_ue50.py ./results/ue50_experiment_20250101_120000/

Output:
    <results_dir>/master_ue50.csv

Schema (one row per 1s observation):
    timestamp           ISO8601
    phase               gnb1_ramp | lb_transition | gnb2_post
    ue_id               50 (constant)
    active_gnb          gnb1 | gnb2
    target_mbps         iperf3 target DL bandwidth (0 = idle)
    # ── RF / RAN metrics (from srsenb metrics CSV) ──
    tti                 TTI index
    nof_ues             number of UEs on this gNB slot
    dl_brate_mbps       DL bitrate Mbps (col 3 of metrics CSV)
    ul_brate_mbps       UL bitrate Mbps
    dl_mcs              DL MCS
    ul_mcs              UL MCS
    dl_snr_db           DL SNR dB
    ul_snr_db           UL SNR dB
    dl_bler             DL BLER
    ul_bler             UL BLER
    phr_db              Power headroom report dB
    # ── CPU metrics (from deep_sysmon.csv) ──
    node_cpu_user_pct
    node_cpu_sys_pct
    node_cpu_iowait_pct
    node_cpu_irq_pct
    node_cpu_softirq_pct
    node_cpu_idle_pct
    node_intr_per_s
    node_ctxt_per_s
    node_softirq_NET_RX_per_s
    node_softirq_NET_TX_per_s
    node_softirq_TIMER_per_s
    node_softirq_SCHED_per_s
    node_softirq_RCU_per_s
    node_net_rx_bytes_s
    node_net_tx_bytes_s
    node_mem_used_MB
    node_load1
    node_load5
    node_load15
    node_temp_core_max_C
    # ── Per-srsenb process (from deep_sysmon) ──
    proc_cpu_user_pct
    proc_cpu_sys_pct
    proc_cpu_total_pct
    proc_rss_kB
    proc_threads
    proc_vol_ctxsw_s
    proc_nonvol_ctxsw_s
    proc_schedrun_ns
    proc_schedwait_ns
    proc_open_fds
    # ── CPU frequency + power (from snapshot files) ──
    cpu_freq_cur_hz     max across cores (from /sys snapshot)
    cpu_power_watts     RAPL package0 power W
    # ── Latency (from ping logs) ──
    ping_rtt_min_ms
    ping_rtt_avg_ms
    ping_rtt_max_ms
    ping_rtt_mdev_ms
    ping_loss_pct
    # ── iperf3 application metrics ──
    iperf_dl_actual_mbps
    iperf_dl_retransmits
    iperf_ul_actual_mbps
    iperf_ul_retransmits
    # ── Handover transition markers ──
    handover_phase      pre | during | post  (only set for lb_transition rows)
    handover_delta_ms   ms since T0 (handover start)
"""

import sys
import os
import re
import csv
import glob
import json
from pathlib import Path
from datetime import datetime

if len(sys.argv) < 2:
    print("Usage: python3 build_master_ue50.py <results_dir>")
    sys.exit(1)

RESULTS_DIR = Path(sys.argv[1])
OUT_CSV = RESULTS_DIR / "master_ue50.csv"

# ── Metrics CSV columns (srsenb format from enb_ue50.conf) ───────────────────
# srsRAN metrics CSV header (semicolon-separated):
# tti;nof_ue;dl_brate;ul_brate;dl_mcs;ul_mcs;dl_snr;ul_snr;dl_bler;ul_bler;phr
METRICS_COLS = [
    "tti", "nof_ues",
    "dl_brate_mbps", "ul_brate_mbps",
    "dl_mcs", "ul_mcs",
    "dl_snr_db", "ul_snr_db",
    "dl_bler", "ul_bler",
    "phr_db"
]

# ── deep_sysmon.csv node-level columns we care about ─────────────────────────
SYSMON_NODE_COLS = [
    "timestamp",
    "node_cpu_user_pct", "node_cpu_sys_pct", "node_cpu_iowait_pct",
    "node_cpu_irq_pct", "node_cpu_softirq_pct", "node_cpu_idle_pct",
    "node_mem_used_MB", "node_load1", "node_load5", "node_load15",
    "node_intr_per_s", "node_ctxt_per_s",
    "node_softirq_NET_RX_per_s", "node_softirq_NET_TX_per_s",
    "node_softirq_TIMER_per_s", "node_softirq_SCHED_per_s",
    "node_softirq_RCU_per_s",
    "node_net_rx_bytes_s", "node_net_tx_bytes_s",
    "node_temp_core_max_C",
]
SYSMON_PROC_COLS = [
    "proc_cpu_user_pct", "proc_cpu_sys_pct", "proc_cpu_total_pct",
    "proc_rss_kB", "proc_threads",
    "proc_vol_ctxsw_s", "proc_nonvol_ctxsw_s",
    "proc_schedrun_ns", "proc_schedwait_ns",
    "proc_open_fds",
]

OUTPUT_COLS = (
    ["timestamp", "phase", "ue_id", "active_gnb", "target_mbps"] +
    METRICS_COLS +
    [c for c in SYSMON_NODE_COLS if c != "timestamp"] +
    SYSMON_PROC_COLS +
    ["cpu_freq_cur_hz", "cpu_power_watts"] +
    ["ping_rtt_min_ms", "ping_rtt_avg_ms", "ping_rtt_max_ms",
     "ping_rtt_mdev_ms", "ping_loss_pct"] +
    ["iperf_dl_actual_mbps", "iperf_dl_retransmits",
     "iperf_ul_actual_mbps", "iperf_ul_retransmits"] +
    ["handover_phase", "handover_delta_ms"]
)


def empty_row():
    return {k: "" for k in OUTPUT_COLS}


# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

def read_sysmon(csv_path):
    """Return list of dicts from a deep_sysmon.csv file."""
    rows = []
    try:
        with open(csv_path, newline="") as f:
            reader = csv.DictReader(f)
            for row in reader:
                rows.append(row)
    except Exception as e:
        print(f"  WARN: could not read sysmon {csv_path}: {e}")
    return rows


def read_metrics_csv(csv_path):
    """Read srsenb metrics CSV (semicolon-delimited, no header)."""
    rows = []
    try:
        with open(csv_path, newline="") as f:
            reader = csv.reader(f, delimiter=";")
            for line in reader:
                if len(line) >= 9:
                    rows.append(line)
    except Exception as e:
        print(f"  WARN: could not read metrics {csv_path}: {e}")
    return rows


def parse_ping_file(ping_path):
    """Parse ping output file → dict with rtt_min/avg/max/mdev/loss."""
    result = {"ping_rtt_min_ms": "", "ping_rtt_avg_ms": "",
              "ping_rtt_max_ms": "", "ping_rtt_mdev_ms": "",
              "ping_loss_pct": ""}
    try:
        text = Path(ping_path).read_text()
        rtt_m = re.search(
            r"rtt min/avg/max/mdev = ([\d.]+)/([\d.]+)/([\d.]+)/([\d.]+)", text)
        if rtt_m:
            result["ping_rtt_min_ms"] = rtt_m.group(1)
            result["ping_rtt_avg_ms"] = rtt_m.group(2)
            result["ping_rtt_max_ms"] = rtt_m.group(3)
            result["ping_rtt_mdev_ms"] = rtt_m.group(4)
        loss_m = re.search(r"(\d+)% packet loss", text)
        if loss_m:
            result["ping_loss_pct"] = loss_m.group(1)
    except Exception:
        pass
    return result


def parse_snapshot_freq_power(snapshot_path):
    """Extract cpu_freq_cur_hz (max core) and cpu_power_watts from snapshot."""
    freq_hz = ""
    power_w = ""
    try:
        text = Path(snapshot_path).read_text()
        freqs = re.findall(r"cur=(\d+)Hz", text)
        if freqs:
            freq_hz = str(max(int(f) for f in freqs))
        pwr = re.findall(r"([\d.]+)W", text)
        # Take the first W reading (package0)
        for p in pwr:
            try:
                val = float(p)
                if val > 0:
                    power_w = str(val)
                    break
            except ValueError:
                pass
    except Exception:
        pass
    return freq_hz, power_w


def parse_iperf_ramp_csv(ramp_csv_path):
    """
    Read ue50_ramp_summary.csv.
    Returns dict: target_mbps → {dl_actual, dl_rtr, ul_actual, ul_rtr}
    """
    result = {}
    try:
        with open(ramp_csv_path, newline="") as f:
            reader = csv.DictReader(f)
            for row in reader:
                bw = row.get("step_mbps", "")
                if bw:
                    result[bw] = {
                        "iperf_dl_actual_mbps": row.get("dl_actual_mbps", ""),
                        "iperf_dl_retransmits": row.get("dl_retransmits", ""),
                        "iperf_ul_actual_mbps": row.get("ul_actual_mbps", ""),
                        "iperf_ul_retransmits": row.get("ul_retransmits", ""),
                    }
    except Exception as e:
        print(f"  WARN: could not read iperf ramp CSV {ramp_csv_path}: {e}")
    return result


def parse_handover_timing(timing_path):
    """Return dict of label → float timestamp from handover_timing.txt"""
    result = {}
    try:
        for line in Path(timing_path).read_text().splitlines():
            if ":" in line:
                k, _, v = line.partition(":")
                try:
                    result[k.strip()] = float(v.strip())
                except ValueError:
                    result[k.strip()] = v.strip()
    except Exception:
        pass
    return result


# ─────────────────────────────────────────────────────────────────────────────
# Section builders
# ─────────────────────────────────────────────────────────────────────────────

def build_gnb1_ramp_rows(ramp_dir, rows_out):
    """Build rows for gnb1 ramp phase."""
    print(f"\n[build] gnb1 ramp: {ramp_dir}")
    ramp_dir = Path(ramp_dir)
    if not ramp_dir.exists():
        print("  WARN: gnb1_ramp dir not found, skipping")
        return

    # Load sysmon
    sysmon_csv = ramp_dir / "sysmon" / "deep_gnb1_ue50_ramp.csv"
    sysmon_rows = read_sysmon(sysmon_csv)
    print(f"  sysmon rows: {len(sysmon_rows)}")

    # Load metrics CSV
    metrics_csv = ramp_dir / "metrics" / "gnb1_ue50_metrics_full.csv"
    metrics_rows = read_metrics_csv(metrics_csv)
    print(f"  metrics rows: {len(metrics_rows)}")

    # Load iperf ramp
    iperf_csv = ramp_dir / "iperf" / "ue50_ramp_summary.csv"
    iperf_data = parse_iperf_ramp_csv(iperf_csv)

    # Load ping per step (we'll use ramp step iperf files for step-specific data)
    ping_files = sorted((ramp_dir / "ping").glob("*.txt")) if (ramp_dir / "ping").exists() else []

    # Load snapshot (cpu freq + power)
    snap_files = sorted(ramp_dir.glob("gnb1_final_snapshot_*.txt"))
    freq_hz, power_w = "", ""
    if snap_files:
        freq_hz, power_w = parse_snapshot_freq_power(snap_files[-1])

    # Align sysmon + metrics by row index (both ~1s interval)
    max_rows = max(len(sysmon_rows), len(metrics_rows), 1)

    for i in range(max_rows):
        row = empty_row()
        row["phase"] = "gnb1_ramp"
        row["ue_id"] = "50"
        row["active_gnb"] = "gnb1"

        # Timestamp from sysmon
        if i < len(sysmon_rows):
            sr = sysmon_rows[i]
            row["timestamp"] = sr.get("timestamp", "")
            for col in SYSMON_NODE_COLS:
                if col != "timestamp":
                    row[col] = sr.get(col, "")
            for col in SYSMON_PROC_COLS:
                row[col] = sr.get(col, "")
        else:
            row["timestamp"] = f"gnb1_ramp_row_{i}"

        # Metrics
        if i < len(metrics_rows):
            mr = metrics_rows[i]
            cols_map = {
                "tti": 0, "nof_ues": 1,
                "dl_brate_mbps": 2, "ul_brate_mbps": 3,
                "dl_mcs": 4, "ul_mcs": 5,
                "dl_snr_db": 6, "ul_snr_db": 7,
                "dl_bler": 8, "ul_bler": 9,
            }
            for col, idx in cols_map.items():
                if idx < len(mr):
                    row[col] = mr[idx].strip()
            if len(mr) > 10:
                row["phr_db"] = mr[10].strip()

        row["cpu_freq_cur_hz"] = freq_hz
        row["cpu_power_watts"] = power_w
        rows_out.append(row)

    # Merge iperf step data as separate rows tagged by target_mbps
    for bw_str, iperf_row in iperf_data.items():
        row = empty_row()
        row["phase"] = "gnb1_ramp"
        row["ue_id"] = "50"
        row["active_gnb"] = "gnb1"
        row["target_mbps"] = bw_str
        row["timestamp"] = f"iperf_step_{bw_str}mbps"
        row.update(iperf_row)
        row["cpu_freq_cur_hz"] = freq_hz
        row["cpu_power_watts"] = power_w

        # Add per-step ping
        ping_path = ramp_dir / "ping" / f"ue50_gnb1_{bw_str}mbps_ping.txt"
        if ping_path.exists():
            row.update(parse_ping_file(str(ping_path)))

        rows_out.append(row)

    print(f"  → {len(rows_out)} total rows after gnb1_ramp")


def build_lb_transition_rows(lb_dir, rows_out):
    """Build rows for load-balance transition phase."""
    print(f"\n[build] lb_transition: {lb_dir}")
    lb_dir = Path(lb_dir)
    if not lb_dir.exists():
        print("  WARN: lb_transition dir not found, skipping")
        return

    # Handover timing
    timing_file = lb_dir / "handover_timing.txt"
    timing = parse_handover_timing(str(timing_file)) if timing_file.exists() else {}
    T0 = timing.get("T0_handover_start", 0)
    try:
        T0 = float(T0)
    except (ValueError, TypeError):
        T0 = 0.0

    # Pre-HO sysmon (gnb1)
    pre_sysmon_csv = lb_dir / "gnb1" / "pre_handover_gnb1_sysmon.csv"
    if not pre_sysmon_csv.exists():
        pre_sysmon_csv = lb_dir / "pre_handover_gnb1_sysmon.csv"
    pre_sysmon = read_sysmon(str(pre_sysmon_csv))
    print(f"  pre-HO sysmon rows: {len(pre_sysmon)}")

    # Pre-HO metrics snapshot
    pre_metrics_csv = lb_dir / "gnb1" / "pre_ho_gnb1_ue50_metrics_tail.csv"
    if not pre_metrics_csv.exists():
        pre_metrics_csv = lb_dir / "pre_ho_gnb1_ue50_metrics_tail.csv"
    pre_metrics = read_metrics_csv(str(pre_metrics_csv))

    # Pre-HO ping
    pre_ping = lb_dir / "gnb1" / "pre_ho_ping_gnb1.txt"
    if not pre_ping.exists():
        pre_ping = lb_dir / "pre_ho_ping_gnb1.txt"
    ping_data = parse_ping_file(str(pre_ping)) if pre_ping.exists() else {}

    # Snapshot
    snap_gnb1 = lb_dir / "gnb1" / "pre_ho_gnb1_system_snapshot.txt"
    if not snap_gnb1.exists():
        snap_gnb1 = lb_dir / "pre_ho_gnb1_system_snapshot.txt"
    freq_gnb1, power_gnb1 = ("", "")
    if snap_gnb1.exists():
        freq_gnb1, power_gnb1 = parse_snapshot_freq_power(str(snap_gnb1))

    max_rows = max(len(pre_sysmon), len(pre_metrics), 1)
    for i in range(max_rows):
        row = empty_row()
        row["phase"] = "lb_transition"
        row["ue_id"] = "50"
        row["active_gnb"] = "gnb1"
        row["handover_phase"] = "pre"
        row["target_mbps"] = "50"

        if i < len(pre_sysmon):
            sr = pre_sysmon[i]
            row["timestamp"] = sr.get("timestamp", f"pre_ho_{i}")
            for col in SYSMON_NODE_COLS:
                if col != "timestamp":
                    row[col] = sr.get(col, "")
            for col in SYSMON_PROC_COLS:
                row[col] = sr.get(col, "")
            # Compute delta from T0
            try:
                ts_epoch = datetime.fromisoformat(sr["timestamp"]).timestamp()
                row["handover_delta_ms"] = f"{(ts_epoch - T0)*1000:.0f}"
            except Exception:
                row["handover_delta_ms"] = ""
        else:
            row["timestamp"] = f"pre_ho_{i}"

        if i < len(pre_metrics):
            mr = pre_metrics[i]
            cols_map = {
                "tti":0,"nof_ues":1,"dl_brate_mbps":2,"ul_brate_mbps":3,
                "dl_mcs":4,"ul_mcs":5,"dl_snr_db":6,"ul_snr_db":7,
                "dl_bler":8,"ul_bler":9,
            }
            for col, idx in cols_map.items():
                if idx < len(mr):
                    row[col] = mr[idx].strip()
            if len(mr) > 10:
                row["phr_db"] = mr[10].strip()

        row.update(ping_data)
        row["cpu_freq_cur_hz"] = freq_gnb1
        row["cpu_power_watts"] = power_gnb1
        rows_out.append(row)

    # Add a single summary row for the handover event itself
    for label, ts_val in timing.items():
        if label.startswith("T") and "_" in label:
            row = empty_row()
            row["phase"] = "lb_transition"
            row["ue_id"] = "50"
            row["handover_phase"] = "during"
            row["timestamp"] = str(ts_val)
            try:
                delta_ms = (float(ts_val) - T0) * 1000
                row["handover_delta_ms"] = f"{delta_ms:.0f}"
            except (ValueError, TypeError):
                row["handover_delta_ms"] = ""
            row["active_gnb"] = "gnb1→gnb2"
            row["target_mbps"] = label  # use label as marker
            rows_out.append(row)

    print(f"  → {len(rows_out)} total rows after lb_transition")


def build_gnb2_post_rows(gnb2_dir, rows_out):
    """Build rows for gnb2 post-handover phase."""
    print(f"\n[build] gnb2 post-HO: {gnb2_dir}")
    gnb2_dir = Path(gnb2_dir)
    if not gnb2_dir.exists():
        print("  WARN: gnb2_post dir not found, skipping")
        return

    # Post-HO sysmon on gnb2
    sysmon_csv = gnb2_dir / "sysmon" / "deep_gnb2_ue50.csv"
    sysmon_rows = read_sysmon(str(sysmon_csv))
    print(f"  post-HO sysmon rows: {len(sysmon_rows)}")

    # gnb2 metrics CSV
    metrics_csv = gnb2_dir / "metrics" / "gnb2_ue50_metrics_full.csv"
    metrics_rows = read_metrics_csv(str(metrics_csv))
    print(f"  gnb2 metrics rows: {len(metrics_rows)}")

    # Post-HO ping
    ping_path = gnb2_dir / "ping" / "ue50_gnb2_max_ping.txt"
    ping_data = parse_ping_file(str(ping_path)) if ping_path.exists() else {}

    # Snapshot
    snap_path = gnb2_dir / "gnb2_post_ho_system_snapshot.txt"
    freq_hz, power_w = ("", "")
    if snap_path.exists():
        freq_hz, power_w = parse_snapshot_freq_power(str(snap_path))

    # iperf ramp CSV if it exists under gnb2 dir
    iperf_csv = gnb2_dir / "iperf" / "ue50_gnb2_iperf.csv"

    max_rows = max(len(sysmon_rows), len(metrics_rows), 1)
    for i in range(max_rows):
        row = empty_row()
        row["phase"] = "gnb2_post"
        row["ue_id"] = "50"
        row["active_gnb"] = "gnb2"
        row["target_mbps"] = "50"

        if i < len(sysmon_rows):
            sr = sysmon_rows[i]
            row["timestamp"] = sr.get("timestamp", f"gnb2_post_{i}")
            for col in SYSMON_NODE_COLS:
                if col != "timestamp":
                    row[col] = sr.get(col, "")
            for col in SYSMON_PROC_COLS:
                row[col] = sr.get(col, "")
        else:
            row["timestamp"] = f"gnb2_post_{i}"

        if i < len(metrics_rows):
            mr = metrics_rows[i]
            cols_map = {
                "tti":0,"nof_ues":1,"dl_brate_mbps":2,"ul_brate_mbps":3,
                "dl_mcs":4,"ul_mcs":5,"dl_snr_db":6,"ul_snr_db":7,
                "dl_bler":8,"ul_bler":9,
            }
            for col, idx in cols_map.items():
                if idx < len(mr):
                    row[col] = mr[idx].strip()
            if len(mr) > 10:
                row["phr_db"] = mr[10].strip()

        row.update(ping_data)
        row["cpu_freq_cur_hz"] = freq_hz
        row["cpu_power_watts"] = power_w
        rows_out.append(row)

    print(f"  → {len(rows_out)} total rows after gnb2_post")


# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

def main():
    print(f"[build_master_ue50] results dir: {RESULTS_DIR}")
    all_rows = []

    build_gnb1_ramp_rows(RESULTS_DIR / "gnb1_ramp", all_rows)
    build_lb_transition_rows(RESULTS_DIR / "lb_transition", all_rows)
    build_gnb2_post_rows(RESULTS_DIR / "gnb2_post", all_rows)

    # Write master CSV
    with open(OUT_CSV, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=OUTPUT_COLS, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(all_rows)

    print(f"\n[build_master_ue50] ✓ Written {len(all_rows)} rows → {OUT_CSV}")
    print(f"  Columns: {len(OUTPUT_COLS)}")
    print(f"  Phases : {set(r['phase'] for r in all_rows)}")


if __name__ == "__main__":
    main()
