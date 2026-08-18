# UE50 Load-Balancing Experiment — Dataset

**Date:** 2026-08-18  **Branch:** `110-ue-scale`  **POWDER testbed**

This directory contains all data collected during the UE50 throughput ramp and
load-balancing handover experiment on the POWDER OpenRAN testbed.

## Experiment Summary

| Parameter | Value |
|-----------|-------|
| UE under test | UE50 (IMSI: 999700000000050) |
| gnb1 load at T0 | 50 UEs |
| gnb1 RAPL power | pkg0=22.39W, pkg1=20.61W, DRAM=3.21W → **total 46.21W** |
| gnb2 RAPL power (post-HO, 1 UE) | pkg0=12.55W, pkg1=9.37W → **total 23.37W** |
| Power saving from LB | **~22.8W (~49.4% reduction)** |
| Throughput ramp steps | 1 / 2 / 5 / 10 / 20 / 50 Mbps (DL + UL) |
| Handover latency (T0→T6) | **239.4 seconds** |
| gnb1 CPU (50 UEs) | mean 20% / max 35% (cpu18 softirq-dominated), load avg 14.11 |
| gnb2 CPU (1 UE) | mean 0.1%, load avg 0.12 |

## Plot-Ready CSVs (use these for paper plots)

| File | Rows | Key columns |
|------|------|-------------|
| `iperf_timeline.csv` | 249 | `epoch_s`, `datetime_utc`, `direction`, `target_bw_mbps`, `gnb`, `mbps`, `gnb_pkg0_watts` |
| `sysmon_timeline.csv` | 249 | `epoch_s`, `gnb`, `node_cpu_user_pct`, `node_cpu_softirq_pct`, `node_softirq_NET_RX_per_s`, `node_intr_per_s`, `node_rapl_package_uj_delta`, `proc_cpu_total_pct`, `node_cpu0_pct`..`node_cpu31_pct` |
| `gnb_metrics_sampled.csv` | 4,059 | `epoch_s`, `gnb`, `target_bw_mbps`, `cpu_mean_pct`, `cpu_max_pct`, `cpu_0_pct`..`cpu_31_pct`, `sys_mem_pct`, `system_load` |
| `handover_events.csv` | 8 | `epoch_s`, `label` (T0–T6), `delta_ms`, `gnb_pkg0_watts`, `power_delta_vs_pre_W` |
| `master_ue50.csv` | 4,540 | All of the above merged (148 columns) |

All CSVs use `epoch_s` (Unix float) + `datetime_utc` (ISO-8601) as time axis.
Experiment wall-clock span: `2026-08-18T10:08:35Z` → `2026-08-18T10:37:42Z` (~29 min).

## Directory Structure

```
ue50_experiment/
├── README.md                    ← this file
├── master_ue50.csv              ← full merged dataset (4540 rows × 148 cols)
├── iperf_timeline.csv           ← plot-ready: throughput over time
├── sysmon_timeline.csv          ← plot-ready: CPU/IRQ/power over time
├── gnb_metrics_sampled.csv      ← plot-ready: per-core CPU over TTI time
├── handover_events.csv          ← plot-ready: HO milestones with epoch
└── raw/
    ├── gnb1/
    │   ├── iperf/               dl/ul_{1,2,5,10,20,50}mbps_raw.json + ramp_summary.csv
    │   ├── ping/                ue50_gnb1_{BW}mbps_ping.txt
    │   ├── sysmon/              deep_gnb1_ue50_ramp.csv (159 rows, 2s interval)
    │   ├── metrics/             README.md + data availability note (322MB files on POWDER)
    │   ├── gnb1_system_snapshot_042446.txt
    │   └── gnb1_rapl_power_snapshot.txt
    └── gnb2/
        ├── iperf/               post_ho_dl/ul_50mbps.json
        ├── ping/                ue50_gnb2_max_ping.txt
        ├── sysmon/              deep_gnb2_ue50.csv (90 rows, 2s interval)
        ├── metrics/             gnb2_ue50_metrics.csv (1281 TTI rows, full unsampled)
        └── gnb2_post_ho_snapshot_043549.txt
```

## Rebuilding the CSVs

```bash
# Rebuild master_ue50.csv from raw data
python3 scripts/build_master_local_v2.py

# Rebuild the 4 plot-ready CSVs with absolute timestamps
python3 scripts/build_plot_csvs.py
```

## Handover Timeline

| Label | delta_ms | epoch_utc | Event |
|-------|----------|-----------|-------|
| T0 | 0 | 10:31:46Z | LB decision. gnb1 50 UEs, pkg0=22.39W |
| T1 | 3,347 | 10:31:49Z | UE50 srsue killed on uehost1 |
| T2 | 43,094 | 10:32:29Z | gnb1 UE50 slot killed. Port 40500 freed |
| T3 | 43,852 | 10:32:29Z | gnb2 srsenb started (GTP=10.10.1.250) |
| T3b | 58,085 | 10:32:44Z | gnb2 ZMQ port 60500 LISTEN. MME accepted |
| T4 | 120,280 | 10:33:46Z | UE50 srsue restarted toward gnb2 |
| T5 | 239,371 | 10:35:45Z | UE50 attached gnb2. IP=10.45.0.51/24 |
| T6 | 239,424 | 10:35:45Z | First ping 0% loss. HO confirmed |
