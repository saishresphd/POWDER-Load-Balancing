#!/usr/bin/env bash
# launch_gnb1_collectors.sh — Start all data collectors on gNB1 (pc818)
# Run from: gNB1 node via master_lb_experiment.sh
set -euo pipefail

COLLECT_DIR="/tmp/ran_collect"
REPO_DIR="${REPO_DIR:-$HOME/POWDER-Load-Balancing}"
DURATION=7200   # 2 hours max

mkdir -p "$COLLECT_DIR"

# System metrics (CPU/mem/net every 5s)
nohup bash "$REPO_DIR/scripts/collect_system_metrics.sh" gnb1 \
    > "$COLLECT_DIR/system_metrics_gnb1.log" 2>&1 &

# Per-UE gNB metrics (nof_ue, sys_load, dl_brate, ul_brate every 5s)
nohup bash "$REPO_DIR/scripts/collect_gnb_metrics.sh" 5 "$DURATION" gnb1 1 51 \
    > "$COLLECT_DIR/gnb_metrics_gnb1.log" 2>&1 &
ln -sf "$COLLECT_DIR/gnb_metrics.csv" "$COLLECT_DIR/gnb_metrics_raw_gnb1.csv"

# RAPL package + DRAM power (1s interval)
nohup bash "$REPO_DIR/scripts/collect_power.sh" gnb1 \
    > "$COLLECT_DIR/power_gnb1.log" 2>&1 &

# Per-core + per-process deep sysmon (2s interval)
nohup python3 "$REPO_DIR/scripts/deep_sysmon.py" "$DURATION" 2 srsenb \
    "$COLLECT_DIR/deep_sysmon_gnb1.csv" \
    > "$COLLECT_DIR/deep_sysmon_gnb1.log" 2>&1 &

# perf IPC / cycles / instructions per core (10s windows)
nohup bash "$REPO_DIR/scripts/collect_perf_ipc.sh" gnb1 \
    > "$COLLECT_DIR/perf_ipc_gnb1.log" 2>&1 &

echo "All gNB1 collectors launched."
