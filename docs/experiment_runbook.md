# POWDER Load-Balancing Experiment Runbook
## UE51 Attach → 500 Mbps Ramp → gNB1→gNB2 Handover

**Branch:** `110-ue-scale`  
**Purpose:** Step-by-step guide to execute the 51-UE load-balancing experiment on the POWDER testbed,
collect comprehensive CPU/power/RAN telemetry, and generate research-grade datasets for CPU power-saving
algorithm design.

---

## Table of Contents
1. [Testbed Node Layout](#1-testbed-node-layout)
2. [Prerequisites](#2-prerequisites)
3. [Pre-Experiment Setup (One-Time)](#3-pre-experiment-setup-one-time)
4. [Script Staging to All Nodes](#4-script-staging-to-all-nodes)
5. [Phase-by-Phase Execution](#5-phase-by-phase-execution)
6. [Data Collection Reference](#6-data-collection-reference)
7. [Log Collection & Merge](#7-log-collection--merge)
8. [Analysis & Key Findings](#8-analysis--key-findings)
9. [Output File Reference](#9-output-file-reference)
10. [Research Metrics Glossary](#10-research-metrics-glossary)
11. [Troubleshooting](#11-troubleshooting)

---

## 1. Testbed Node Layout

| Role     | Node  | Internal IP  | Emulab FQDN            | Key Process |
|----------|-------|-------------|------------------------|-------------|
| core     | pc811 | 10.10.1.1   | saish@pc811.emulab.net | Open5GS, iperf3-server |
| gnb1     | pc818 | 10.10.1.2   | saish@pc818.emulab.net | srsENB (gNB1), ZMQ |
| gnb2     | pc802 | 10.10.1.3   | saish@pc802.emulab.net | srsENB (gNB2), ZMQ |
| uehost1  | pc808 | 10.10.1.4   | saish@pc808.emulab.net | UEs 1–50, master orchestrator |
| uehost2  | pc801 | 10.10.1.5   | saish@pc801.emulab.net | UE51, lb experiment script |

> **SSH pattern:** `ssh -o StrictHostKeyChecking=no saish@<FQDN>`

---

## 2. Prerequisites

### 2.1 POWDER Reservation
- Ensure your Emulab experiment is **active** and all 5 nodes are **ready** (green).
- Verify network: `ping -c2 10.10.1.1` from each node must succeed.

### 2.2 Software Requirements (all nodes)
```bash
# srsRAN must be built with ZMQ support
which srsenb && which srsue   # must return paths

# iperf3
iperf3 --version

# Python3 + pandas (for analysis scripts)
python3 -c "import pandas; print(pandas.__version__)"

# perf (for IPC collection) — on gNB nodes only
sudo apt-get install -y linux-tools-$(uname -r) linux-tools-generic

# Relax perf paranoia
sudo sysctl -w kernel.perf_event_paranoid=1
```

### 2.3 RAPL Power Interface (gNB nodes only)
```bash
# Load RAPL module
sudo modprobe intel_rapl_common 2>/dev/null || true
sudo modprobe intel_rapl_msr 2>/dev/null || true

# Verify RAPL is accessible
ls /sys/class/powercap/intel-rapl/intel-rapl:0/energy_uj

# Grant world-read (or run collect_power.sh with sudo)
sudo chmod o+r /sys/class/powercap/intel-rapl/intel-rapl:0/energy_uj
sudo chmod o+r /sys/class/powercap/intel-rapl/intel-rapl:1/energy_uj  2>/dev/null || true
```

### 2.4 Open5GS Core (pc811)
```bash
# Must be running BEFORE any UE attaches
systemctl status open5gs-mmed  # or equivalent service name
systemctl status open5gs-sgwd

# If not running:
sudo systemctl start open5gs-mmed open5gs-sgwd open5gs-pgwd
```

### 2.5 Subscribers in HSS
50 UEs (IMSI 001011234567891–001011234567940) + UE51 (IMSI 001011234567941) must all be
registered in Open5GS HSS/MongoDB.  
Run on pc811 if not already done:
```bash
cd ~/POWDER-Load-Balancing
node scripts/add_subscribers_100.js   # idempotent — safe to re-run
```

---

## 3. Pre-Experiment Setup (One-Time)

### 3.1 Clone / pull repo on ALL nodes
```bash
REPO="https://github.com/saishresphd/POWDER-Load-Balancing"
BRANCH="110-ue-scale"
DEST="$HOME/POWDER-Load-Balancing"

for NODE in pc811.emulab.net pc818.emulab.net pc802.emulab.net pc808.emulab.net pc801.emulab.net; do
  ssh -o StrictHostKeyChecking=no saish@$NODE "
    if [ -d $DEST ]; then
      cd $DEST && git fetch origin && git checkout $BRANCH && git pull origin $BRANCH
    else
      git clone -b $BRANCH $REPO $DEST
    fi
  " &
done
wait
echo "Git pull done on all nodes"
```

### 3.2 Create runtime directories on ALL nodes
```bash
for NODE in pc811.emulab.net pc818.emulab.net pc802.emulab.net pc808.emulab.net pc801.emulab.net; do
  ssh -o StrictHostKeyChecking=no saish@$NODE "mkdir -p /tmp/ran_collect /tmp/ran_collect/results" &
done
wait
```

### 3.3 Make all scripts executable on ALL nodes
```bash
for NODE in pc811.emulab.net pc818.emulab.net pc802.emulab.net pc808.emulab.net pc801.emulab.net; do
  ssh -o StrictHostKeyChecking=no saish@$NODE "
    chmod +x ~/POWDER-Load-Balancing/scripts/*.sh 2>/dev/null
    chmod +x ~/POWDER-Load-Balancing/scripts/*.py 2>/dev/null
  " &
done
wait
```

---

## 4. Script Staging to All Nodes

The orchestrator (`run_ue51_lb_experiment.sh`) expects all collectors at `/tmp/ran_collect/`.
Run this from **uehost1 (pc808)** once before the experiment:

```bash
# Run on pc808 (uehost1)
REPO="$HOME/POWDER-Load-Balancing"
COLLECT_DIR="/tmp/ran_collect"

# Stage to local COLLECT_DIR
cp $REPO/scripts/*.sh   $COLLECT_DIR/
cp $REPO/scripts/*.py   $COLLECT_DIR/
cp $REPO/configs        $COLLECT_DIR/ -r
chmod +x $COLLECT_DIR/*.sh $COLLECT_DIR/*.py

# Stage to all remote nodes
for NODE in pc811.emulab.net pc818.emulab.net pc802.emulab.net pc801.emulab.net; do
  ssh -o StrictHostKeyChecking=no saish@$NODE "mkdir -p $COLLECT_DIR/configs" &
  scp -o StrictHostKeyChecking=no $REPO/scripts/*.sh  saish@$NODE:$COLLECT_DIR/ &
  scp -o StrictHostKeyChecking=no $REPO/scripts/*.py  saish@$NODE:$COLLECT_DIR/ &
  scp -o StrictHostKeyChecking=no -r $REPO/configs    saish@$NODE:$COLLECT_DIR/ &
done
wait
echo "Staging complete"
```

---

## 5. Phase-by-Phase Execution

### 5.1 Launch gNB1 (pc818)

Open a dedicated terminal on pc818:

```bash
ssh saish@pc818.emulab.net
cd ~/POWDER-Load-Balancing
sudo srsenb configs/gnb1/enb.conf \
  --enb.n_prb=100 \
  --rf.device_name=zmq \
  --rf.device_args="fail_on_disconnect=true,id=enb,base_srate=23.04e6,tx_port=tcp://*:2000,rx_port=tcp://10.10.1.4:2001,tx_port2=tcp://*:2100,rx_port2=tcp://10.10.1.5:40511" \
  2>&1 | tee /tmp/ran_collect/gnb1_main.log
```

> **Note:** The `rx_port2` listens for UE51 from uehost2 (10.10.1.5:40511).  
> Leave this terminal open throughout the experiment.

### 5.2 Launch gNB2 (pc802)

Open a dedicated terminal on pc802:

```bash
ssh saish@pc802.emulab.net
cd ~/POWDER-Load-Balancing
sudo srsenb configs/gnb2/enb.conf \
  --enb.n_prb=100 \
  --rf.device_name=zmq \
  --rf.device_args="fail_on_disconnect=true,id=enb2,base_srate=23.04e6,tx_port=tcp://*:3000,rx_port=tcp://10.10.1.5:50011" \
  2>&1 | tee /tmp/ran_collect/gnb2_main.log
```

### 5.3 Verify 50 UEs are attached to gNB1 (uehost1 / pc808)

```bash
ssh saish@pc808.emulab.net
cd ~/POWDER-Load-Balancing
bash scripts/check_all_ues.sh
# Expected: 50 UEs with tun_srsue* interfaces UP
```

If fewer than 50 are attached:
```bash
bash scripts/attach_50ue_fast.sh   # re-attach all 50 UEs
sleep 30
bash scripts/check_all_ues.sh     # re-verify
```

### 5.4 Run the Full Experiment (PRIMARY ENTRY POINT)

> **Run from uehost1 (pc808) only.**

```bash
ssh saish@pc808.emulab.net
cd ~/POWDER-Load-Balancing
bash scripts/master_lb_experiment.sh 2>&1 | tee /tmp/ran_collect/master_run.log
```

The master script executes these phases automatically:

| Phase | Name | Duration | What Happens |
|-------|------|----------|--------------|
| 1 | PRE_FLIGHT | ~30 s | Git pull on all 5 nodes, verify UE count ≥50 |
| 2 | BASELINE_COLLECTION | 10 s warmup | Starts all collectors on all nodes |
| 3 | UE51_ATTACH_GNB1 | 20 s wait | `deploy_ues_51_100_v2.sh 51 51` on uehost2; UE51 attaches to gNB1 |
| 4 | THROUGHPUT_RAMP_500MBPS | ~30 s ramp + 30 s hold | iperf3 ramp on UEs 1–51; records peak throughput |
| 5 | LB_TRIGGER | instant | Records `LB_TS_MS`; starts handover monitor; calls `run_ue51_lb_experiment.sh` |
| 6 | LB_TRANSITION | ≤120 s | Polls every 5 s for UE51 on gNB2; records `HANDOVER_DURATION_MS` |
| 7 | POST_LB_STEADY | 60 s | Steady-state after handover; all collectors still running |
| 8 | LOG_COLLECTION | ~60 s | SCP all CSVs/txts from all nodes → `$RESULTS_DIR/<node>/` |
| 9 | ANALYSIS | ~10 s | Runs `analyze_lb_results.py`; CLEANUP: kills all collectors |

> **Total runtime:** ~7–10 minutes.  
> Monitor progress via: `tail -f /tmp/ran_collect/master_run.log`

### 5.5 Sub-Experiment on uehost2 (called automatically by master)

`run_ue51_lb_experiment.sh` is invoked by the master and runs on pc801. It executes:

| Phase | Duration | Detail |
|-------|----------|--------|
| 1 — Baseline 50 UEs | 60 s | 20 Mbps ramp via `run_iperf_ramp.sh` |
| 2 — UE51 Attach gNB1 | ≤30 s | `srsue ue51.conf`; waits for `tun_srsue` UP |
| 3 — Ramp UE51 to 500 Mbps | ~90 s | 13-step ramp: 20→50→100→150→200→250→300→350→400→430→460→480→500 Mbps |
| 4 — Hold 500 Mbps | 60 s | Steady-state with all 51 UEs at peak load |
| 5 — LB Trigger | instant | SIGTERM srsue UE51; records `DETACH_TS` |
| 6 — Handover | ≤120 s | `srsue ue51_gnb2.conf`; waits `tun_srsue` UP; records `ATTACH_TS`, `HANDOVER_DURATION_MS` |
| 7 — Post-LB Steady | 60 s | Final iperf3 run; stops collectors; writes `experiment_summary.txt` |

---

## 6. Data Collection Reference

All collectors are started automatically by the master/sub-experiment scripts.
This section documents what each collector captures for research reference.

### 6.1 System Metrics (`collect_system_metrics.sh`) — ALL NODES
**Interval:** 5 s  
**Output:** `/tmp/ran_collect/system_metrics_<node>.csv`

| Column | Description |
|--------|-------------|
| `timestamp` | Unix epoch seconds |
| `elapsed_s` | Seconds since collector start |
| `cpu_util_pct` | Overall CPU utilization % (all cores) |
| `mem_used_mb` | RSS memory used (MB) |
| `net_rx_mbps` | Network receive throughput (Mbps) |
| `net_tx_mbps` | Network transmit throughput (Mbps) |
| `load_avg_1m` | 1-min load average |
| `phase` | Experiment phase label (injected at merge) |

### 6.2 RAPL Power (`collect_power.sh`) — gNB1 & gNB2 ONLY
**Interval:** 1 s  
**Output:** `/tmp/ran_collect/power_gnb1.csv`, `/tmp/ran_collect/power_gnb2.csv`  
**Requires:** `sudo` or RAPL files world-readable

| Column | Description |
|--------|-------------|
| `timestamp` | Unix epoch seconds |
| `elapsed_s` | Seconds since collector start |
| `pkg0_power_W` | CPU package 0 power draw (Watts) |
| `pkg1_power_W` | CPU package 1 power draw (Watts) — 0 if single-socket |
| `dram0_power_W` | DRAM channel 0 power draw (Watts) |
| `dram1_power_W` | DRAM channel 1 power draw (Watts) |
| `cpu0_freq_MHz` | Current CPU0 clock frequency (MHz) |
| `cpu_max_freq_MHz` | Maximum CPU frequency (MHz) |

> **Research use:** Compute energy-per-bit = total_energy_J / total_bytes_transferred

### 6.3 Deep System Monitor (`deep_sysmon.py`) — gNB1 & gNB2
**Interval:** 2 s  
**Output:** `/tmp/ran_collect/deep_sysmon_gnb1.csv`, `deep_sysmon_gnb2.csv`

| Column | Description |
|--------|-------------|
| `timestamp` | Unix epoch seconds |
| `core_N_util_pct` | Per-core CPU utilization (one column per core) |
| `proc_srsenb_cpu_pct` | srsenb process CPU % |
| `proc_srsenb_mem_rss_mb` | srsenb RSS memory (MB) |
| `proc_srsenb_threads` | srsenb thread count |
| `ctx_switches_vol` | Voluntary context switches (delta) |
| `ctx_switches_invol` | Involuntary context switches (delta) |
| `irq_rate` | Interrupts per second |
| `softirq_rate` | Soft-IRQ rate |
| `temp_core0_C` | CPU core 0 temperature (°C) — if hwmon available |

### 6.4 perf IPC (`collect_perf_ipc.sh`) — gNB1 ONLY
**Interval:** 1 s  
**Output:** `/tmp/ran_collect/perf_ipc_gnb1.csv`

| Column | Description |
|--------|-------------|
| `timestamp` | Unix epoch seconds |
| `core` | CPU core number |
| `instructions` | Instructions retired (delta) |
| `cycles` | CPU cycles (delta) |
| `ipc` | Instructions-per-cycle = instructions/cycles |
| `cache_misses` | LLC cache misses (delta) |
| `cache_refs` | LLC cache references (delta) |

> **Research use:** Low IPC + high load → memory-bound processing → DRAM power dominates

### 6.5 gNB RAN Metrics (`collect_gnb_metrics.sh` / `collect_rich_gnb1.sh`) — gNB nodes
**Interval:** 1 s  
**Output:** `/tmp/ran_collect/gnb_metrics_gnb1.csv`, `gnb_metrics_raw_gnb1.csv`

| Column | Description |
|--------|-------------|
| `timestamp` | Unix epoch seconds |
| `rnti` | UE radio network temp identifier |
| `dl_bitrate_mbps` | Downlink bitrate (Mbps) per UE |
| `ul_bitrate_mbps` | Uplink bitrate (Mbps) per UE |
| `dl_mcs` | Downlink MCS (Modulation & Coding Scheme) |
| `ul_mcs` | Uplink MCS |
| `snr_db` | Signal-to-noise ratio (dB) |
| `buffer_bytes` | DL buffer occupancy (bytes) |
| `active_ue_count` | Total active UEs this interval |
| `total_dl_mbps` | Sum of all UE DL bitrates (Mbps) |
| `total_ul_mbps` | Sum of all UE UL bitrates (Mbps) |

### 6.6 Handover Events (`collect_ue51_handover.sh`) — uehost2
**Interval:** 500 ms  
**Output:** `/tmp/ran_collect/ue51_handover.csv`, `ue51_handover_summary.txt`

| Column | Description |
|--------|-------------|
| `timestamp_ms` | Unix epoch milliseconds |
| `elapsed_ms` | ms since collector start |
| `ue51_state` | `ATTACHED_GNB1` / `DETACHING` / `ATTACHING_GNB2` / `ATTACHED_GNB2` |
| `tun_up` | `0` or `1` — tun_srsue interface is UP |
| `ping_rtt_ms` | ICMP RTT to core (ms) — `null` if unreachable |
| `iperf_throughput_mbps` | Instantaneous iperf throughput (Mbps) — `null` during transition |

### 6.7 iperf3 Throughput (`run_iperf_500mbps.sh`) — uehost1/2
**Output:** `/tmp/ran_collect/iperf_results_500.csv`

| Column | Description |
|--------|-------------|
| `timestamp` | Unix epoch seconds |
| `ue_id` | UE number (1–51) |
| `target_mbps` | Configured iperf target (Mbps) |
| `actual_mbps` | Achieved throughput (Mbps) |
| `retransmits` | TCP retransmit count |
| `phase` | `BASELINE` / `RAMP` / `HOLD_500` / `POST_LB` |

---

## 7. Log Collection & Merge

### 7.1 Automatic Collection (done by master script)
After all phases complete, the master script SCPs all output files to uehost1:
```
$RESULTS_DIR/
  gnb1/    — all CSV/txt from pc818
  gnb2/    — all CSV/txt from pc802
  core/    — all CSV/txt from pc811
  uehost2/ — all CSV/txt from pc801
  uehost1/ — local CSV/txt from pc808
```

### 7.2 Manual Collection (if master script fails mid-way)
Run from uehost1 (pc808):

```bash
RESULTS="$HOME/lb_results_$(date +%Y%m%d_%H%M%S)"
mkdir -p $RESULTS/{gnb1,gnb2,core,uehost2,uehost1}

scp -o StrictHostKeyChecking=no "saish@pc818.emulab.net:/tmp/ran_collect/*.csv" $RESULTS/gnb1/
scp -o StrictHostKeyChecking=no "saish@pc818.emulab.net:/tmp/ran_collect/*.txt" $RESULTS/gnb1/
scp -o StrictHostKeyChecking=no "saish@pc802.emulab.net:/tmp/ran_collect/*.csv" $RESULTS/gnb2/
scp -o StrictHostKeyChecking=no "saish@pc802.emulab.net:/tmp/ran_collect/*.txt" $RESULTS/gnb2/
scp -o StrictHostKeyChecking=no "saish@pc811.emulab.net:/tmp/ran_collect/*.csv" $RESULTS/core/
scp -o StrictHostKeyChecking=no "saish@pc801.emulab.net:/tmp/ran_collect/*.csv" $RESULTS/uehost2/
scp -o StrictHostKeyChecking=no "saish@pc801.emulab.net:/tmp/ran_collect/*.txt" $RESULTS/uehost2/
cp /tmp/ran_collect/*.csv $RESULTS/uehost1/
cp /tmp/ran_collect/*.txt $RESULTS/uehost1/

echo "All logs collected to $RESULTS"
```

### 7.3 Merge CSVs into Master Dataset
```bash
cd $HOME/POWDER-Load-Balancing
python3 scripts/merge_ran_csv.py \
  --results-dir $RESULTS \
  --handover-summary $RESULTS/uehost2/ue51_handover_summary.txt \
  --output $RESULTS/results/master_dataset.csv

echo "Master dataset: $RESULTS/results/master_dataset.csv"
```

### 7.4 Build Phase-Labelled Dataset
```bash
python3 scripts/build_master_v4.py \
  --input $RESULTS/results/master_dataset.csv \
  --lb-trigger-file $RESULTS/uehost1/lb_trigger.txt \
  --output $RESULTS/results/phase_labelled_dataset.csv
```

---

## 8. Analysis & Key Findings

### 8.1 Automated Analysis
```bash
python3 scripts/analyze_lb_results.py \
  --results-dir $RESULTS \
  --output-dir $RESULTS/results/
# Generates: key_findings.txt, lb_analysis.csv, phase_summary.csv
```

### 8.2 Key Research Metrics to Extract

The following queries on `master_dataset.csv` or `phase_labelled_dataset.csv` yield the
most valuable findings for CPU power-saving algorithm design:

#### A. Handover Latency
```bash
grep "HANDOVER_DURATION_MS\|DETACH_TS\|ATTACH_TS" $RESULTS/uehost2/ue51_handover_summary.txt
```
**Why it matters:** Defines the minimum reaction window for any power-scaling algorithm.
During the gap (`DETACH_TS` → `ATTACH_TS`), gNB1 carries 50 UEs — ideal moment to
reduce CPU frequency or park cores.

#### B. CPU Utilization vs UE Count
```python
import pandas as pd
df = pd.read_csv("gnb_metrics_gnb1.csv")
sys = pd.read_csv("system_metrics_gnb1.csv")
merged = pd.merge_asof(df.sort_values("timestamp"), sys.sort_values("timestamp"),
                       on="timestamp", tolerance=3)
print(merged.groupby("active_ue_count")["cpu_util_pct"].describe())
```
**Why it matters:** Reveals the CPU headroom when UE count drops — quantifies how much
power could be saved with fewer UEs.

#### C. Power vs Load Phase
```python
pwr = pd.read_csv("power_gnb1.csv")
pwr["total_pkg_W"] = pwr["pkg0_power_W"] + pwr["pkg1_power_W"]
print(pwr.groupby("phase")["total_pkg_W"].agg(["mean","std","min","max"]))
```
**Why it matters:** Baseline (50 UEs, 500 Mbps) vs Post-LB (50 UEs, handover load released)
power delta = achievable saving from load balancing.

#### D. IPC Efficiency vs Throughput
```python
ipc = pd.read_csv("perf_ipc_gnb1.csv")
tput = pd.read_csv("gnb_metrics_gnb1.csv")
# Low IPC at high load → CPU is memory-bound → DRAM power matters more
print(ipc.groupby("phase")["ipc"].mean())
```
**Why it matters:** If IPC < 1.0 at peak load, the bottleneck is memory bandwidth, not
compute — suggests DRAM power optimisation is higher priority than DVFS.

#### E. Energy-per-Bit
```python
# For each phase:
# E_J = sum(pkg_power_W) * interval_s
# bits = sum(dl_mbps + ul_mbps) * 1e6 * interval_s
# EPB = E_J / bits  (J/bit)
```
**Why it matters:** Primary metric for green RAN. Comparison across phases shows which
operating point minimises energy cost per delivered bit.

#### F. CPU Frequency Behaviour
```python
print(pwr.groupby("phase")["cpu0_freq_MHz"].agg(["mean","min","max"]))
```
**Why it matters:** If frequency doesn't scale down when load drops (post-LB), the OS
governor is not responding — identifies opportunity for custom power management.

#### G. Context Switch Rate vs UE Count
```python
deep = pd.read_csv("deep_sysmon_gnb1.csv")
print(deep.groupby("phase")[["ctx_switches_invol","irq_rate"]].mean())
```
**Why it matters:** High involuntary context switches at moderate UE count indicate
scheduler pressure — can be reduced via CPU pinning and NUMA-aware allocation.

#### H. Temperature vs Power vs Frequency (Thermal Headroom)
```python
print(deep.groupby("phase")[["temp_core0_C"]].mean())
print(pwr.groupby("phase")[["pkg0_power_W","cpu0_freq_MHz"]].mean())
```
**Why it matters:** If temperature headroom > 15°C, the CPU can run hotter (and thus
faster) without thermal throttle — enabling burst power modes for brief peak loads.

---

## 9. Output File Reference

| File | Node | Interval | Key Columns |
|------|------|----------|-------------|
| `system_metrics_gnb1.csv` | gnb1 | 5 s | cpu_util_pct, mem_used_mb, net_rx/tx_mbps |
| `system_metrics_gnb2.csv` | gnb2 | 5 s | same as above |
| `power_gnb1.csv` | gnb1 | 1 s | pkg0/1_power_W, dram0/1_power_W, cpu0_freq_MHz |
| `power_gnb2.csv` | gnb2 | 1 s | same as above |
| `deep_sysmon_gnb1.csv` | gnb1 | 2 s | per-core util, ctx_switches, irq_rate, temp |
| `deep_sysmon_gnb2.csv` | gnb2 | 2 s | same as above |
| `perf_ipc_gnb1.csv` | gnb1 | 1 s | core, ipc, instructions, cycles, cache_misses |
| `gnb_metrics_gnb1.csv` | gnb1 | 1 s | rnti, dl/ul_mbps, mcs, snr, active_ue_count |
| `gnb_metrics_gnb2.csv` | gnb2 | 1 s | same as above |
| `gnb_metrics_raw_gnb1.csv` | gnb1 | 1 s | raw srsenb semicolon-delimited log |
| `ue51_handover.csv` | uehost2 | 500 ms | ue51_state, tun_up, ping_rtt_ms |
| `ue51_handover_summary.txt` | uehost2 | event | HANDOVER_DURATION_MS, DETACH_TS, ATTACH_TS |
| `iperf_results_500.csv` | uehost1 | per-run | ue_id, target_mbps, actual_mbps, phase |
| `lb_trigger.txt` | uehost1 | event | lb_trigger_ts_ms |
| `experiment_summary.txt` | uehost1 | event | all timing + 8 Key Research Findings |
| `master_dataset.csv` | uehost1 | merged | all columns time-aligned, phase-labelled |
| `phase_labelled_dataset.csv` | uehost1 | merged | master_dataset + phase labels injected |
| `key_findings.txt` | uehost1 | post | human-readable research findings |
| `lb_analysis.csv` | uehost1 | post | per-phase aggregated metrics |

---

## 10. Research Metrics Glossary

| Metric | Symbol | Unit | Definition |
|--------|--------|------|------------|
| Handover Duration | HO_D | ms | Time from UE51 SIGTERM to `tun_srsue` UP on gNB2 |
| End-to-End LB Duration | E2E_D | ms | Time from LB trigger decision to UE51 stable on gNB2 |
| CPU Utilization | CPU_U | % | `(1 - idle/total) × 100` sampled over 5 s |
| RAPL Package Power | P_pkg | W | `(energy_uj_delta / time_us_delta)` for intel-rapl:0 |
| DRAM Power | P_dram | W | `(energy_uj_delta / time_us_delta)` for intel-rapl:0:0 |
| IPC | IPC | dimensionless | `instructions_delta / cycles_delta` (perf stat) |
| Energy per Bit | EPB | J/bit | `P_total × interval_s / (throughput_bps × interval_s)` |
| UE Count | N_UE | — | Active UEs served by a gNB at a given timestamp |
| Throughput | T | Mbps | Aggregate DL+UL across all UEs |
| CPU Frequency | F_cpu | MHz | `scaling_cur_freq` from cpufreq sysfs |
| IRQ Rate | IRQ/s | irq/s | `/proc/interrupts` delta |
| Involuntary Context Switches | ICS/s | — | `prstat` or `/proc/<pid>/status` voluntary_ctxt_switches delta |
| Cache Miss Rate | CMR | % | `cache_misses / cache_refs × 100` |
| Thermal Headroom | TH | °C | `T_max (95°C) - T_core_current` |

---

## 11. Troubleshooting

### UE51 fails to attach to gNB1 within 30 s
```bash
# On pc818 (gnb1) — check if ZMQ port 40511 is listening
ss -tnlp | grep 40511

# On pc801 (uehost2) — check srsue log
tail -50 /tmp/ran_collect/ue51_gnb1.log | grep -E "RACH|Attach|ERROR|FAIL"

# Manual retry
ssh saish@pc801.emulab.net "killall srsue 2>/dev/null; \
  srsue ~/POWDER-Load-Balancing/configs/ues/ue51.conf \
  2>&1 | tee /tmp/ran_collect/ue51_gnb1.log &"
```

### iperf3 throughput stalls below 500 Mbps
```bash
# Check iperf3 server is running on core
ssh saish@pc811.emulab.net "pgrep -a iperf3"
# If not: ssh saish@pc811.emulab.net "iperf3 -s -D -p 5201"

# Check network path
ssh saish@pc808.emulab.net "iperf3 -c 10.10.1.1 -u -b 500M -t 5"
```

### RAPL power reads are all zero
```bash
# Check module loaded
lsmod | grep intel_rapl
# If missing:
sudo modprobe intel_rapl_common
sudo modprobe intel_rapl_msr

# Check file permissions
ls -la /sys/class/powercap/intel-rapl/intel-rapl:0/energy_uj
# Fix: sudo chmod o+r /sys/class/powercap/intel-rapl/*/energy_uj
```

### perf IPC collection fails with "Permission denied"
```bash
sudo sysctl -w kernel.perf_event_paranoid=0
# Or run collect_perf_ipc.sh with sudo
```

### UE51 handover to gNB2 times out (>120 s)
```bash
# Verify gNB2 is running and listening
ssh saish@pc802.emulab.net "pgrep -a srsenb"
ssh saish@pc802.emulab.net "ss -tnlp | grep 3000"

# Check ue51_gnb2.conf port matches gNB2
grep rx_port ~/POWDER-Load-Balancing/configs/ues/ue51_gnb2.conf
# Should be: rx_port=tcp://10.10.1.3:50010

# Manual attach attempt
ssh saish@pc801.emulab.net "killall srsue 2>/dev/null; sleep 2; \
  srsue ~/POWDER-Load-Balancing/configs/ues/ue51_gnb2.conf \
  2>&1 | tee /tmp/ran_collect/ue51_gnb2.log &"
sleep 30
ssh saish@pc801.emulab.net "ip addr show | grep tun_srsue"
```

### master_lb_experiment.sh exits early
```bash
# Check master log for ERROR lines
grep -E "ERROR|FAIL|ABORT" /tmp/ran_collect/master_run.log

# Resume from a specific phase manually:
# Phase 3 onward (UE51 already attached):
ssh saish@pc808.emulab.net "bash ~/POWDER-Load-Balancing/scripts/run_iperf_500mbps.sh"

# Or run sub-experiment directly on uehost2:
ssh saish@pc801.emulab.net "bash ~/POWDER-Load-Balancing/scripts/run_ue51_lb_experiment.sh \
  2>&1 | tee /tmp/ran_collect/ue51_lb_run.log"
```

### Clean up all processes between runs
```bash
for NODE in pc811.emulab.net pc818.emulab.net pc802.emulab.net pc808.emulab.net pc801.emulab.net; do
  ssh -o StrictHostKeyChecking=no saish@$NODE "bash ~/POWDER-Load-Balancing/scripts/kill_all.sh" &
done
wait
# Then clear runtime data if needed:
for NODE in pc811.emulab.net pc818.emulab.net pc802.emulab.net pc808.emulab.net pc801.emulab.net; do
  ssh -o StrictHostKeyChecking=no saish@$NODE "rm -f /tmp/ran_collect/*.csv /tmp/ran_collect/*.txt" &
done
wait
echo "All nodes cleaned"
```

---

*Last updated: auto-generated for branch `110-ue-scale`*  
*Repository: [saishresphd/POWDER-Load-Balancing](https://github.com/saishresphd/POWDER-Load-Balancing/tree/110-ue-scale)*
