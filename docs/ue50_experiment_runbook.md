# UE50 Load-Balancing Experiment — Complete Runbook
> **Branch:** `110-ue-scale` · **Scenario:** Add UE50 to gnb1 (50th UE), ramp throughput,
> collect all telemetry, then load-balance UE50 to gnb2

---

## Topology

| Node    | FQDN              | IP         | Role                             |
|---------|-------------------|------------|----------------------------------|
| core    | pc811.emulab.net  | 10.10.1.1  | Open5GS EPC (MME·SGW·UPF·HSS)   |
| gnb1    | pc818.emulab.net  | 10.10.1.2  | srsRAN srsenb — UE1–100 (base)   |
| gnb2    | pc802.emulab.net  | 10.10.1.3  | srsRAN srsenb — LB targets        |
| uehost1 | pc808.emulab.net  | 10.10.1.4  | srsue — UE1–100 (ue1–ue100 ns)   |

### UE50 port assignment

| Phase         | gNB TX REP (pc818) | UE TX REP (pc808) | gtp_bind_addr |
|---------------|--------------------|-------------------|---------------|
| gnb1 (base)   | `*:40500`          | `pc808:40501`     | 10.10.1.148   |
| gnb2 (post-LB)| `*:60500`          | `pc808:60501`     | 10.10.1.250   |

---

## Data Collected

### On gnb1 / gnb2 — RAN Metrics (`/tmp/gnb{1,2}_ue50_metrics.csv`)
Emitted by srsenb at 1s interval; semicolon-delimited. Columns:

| Col | Field          | Description                              |
|-----|----------------|------------------------------------------|
| 1   | `tti`          | Transmission time interval index         |
| 2   | `nof_ues`      | Active UEs on this gNB slot              |
| 3   | `dl_brate`     | DL bit-rate Mbps                         |
| 4   | `ul_brate`     | UL bit-rate Mbps                         |
| 5   | `dl_mcs`       | DL modulation-coding scheme (0–28)       |
| 6   | `ul_mcs`       | UL MCS                                   |
| 7   | `dl_snr`       | DL SNR dB                                |
| 8   | `ul_snr`       | UL SNR dB                                |
| 9   | `dl_bler`      | DL block error rate                      |
| 10  | `ul_bler`      | UL BLER                                  |
| 11  | `phr`          | Power headroom report (dB)               |

> **PDCP** throughput is captured via the `dl_brate`/`ul_brate` columns above — these reflect
> the PDCP SDU delivery rate at the gNB layer.

### On gnb1 / gnb2 — deep_sysmon (`/tmp/ran_collect/*/sysmon/deep_*.csv`)
Per-core CPU%, IRQ/s, softIRQ breakdown, context switches, schedstat (IPC proxy), RAM,
network rx/tx bytes, CPU temperatures. See `scripts/deep_sysmon.py` header for full schema.

### Latency — ping logs (`/tmp/ran_collect/*/ping/*.txt`)
RTT min/avg/max/mdev and packet loss at each iperf3 throughput step.

### Application throughput — iperf3 (`/tmp/ran_collect/*/iperf/ue50_ramp_summary.csv`)
DL and UL actual Mbps, retransmits, jitter, CPU usage at each ramp step.

### CPU power — RAPL snapshot (`gnb{1,2}_*_snapshot.txt`)
Intel RAPL package0 power in Watts (sampled over 1 second).

### CPU frequency — sysfs snapshot
Per-core `scaling_cur_freq` and governor at each snapshot point.

---

## Prerequisites

1. **49 UEs (UE1–49) already attached on gnb1** — use existing `start_network.sh` for UE1–49.
2. **Open5GS core running on pc811** — all services `active`.
3. **`enb_ue50.conf` deployed to `/etc/srsenb/` on pc818** — already in repo `configs/gnb1/enb_ue50.conf`.
4. **`ue50.conf` deployed to `/etc/srsue/` on pc808** — already in repo `configs/ues/ue50.conf`.
5. **IP alias 10.10.1.148 on pc818** — must exist (from existing alias setup script).
6. **`deep_sysmon.py` accessible on local machine at `scripts/deep_sysmon.py`** — already in repo.
7. **iperf3 installed on pc811** (`sudo apt install -y iperf3` if not present).

---

## Step 1 — Deploy configs (once)

```bash
# From local machine, inside repo root

# Deploy UE50 gNB config to gnb1
scp configs/gnb1/enb_ue50.conf saish@pc818.emulab.net:/tmp/
ssh saish@pc818.emulab.net 'sudo cp /tmp/enb_ue50.conf /etc/srsenb/'

# Deploy UE50 UE config to uehost1
scp configs/ues/ue50.conf saish@pc808.emulab.net:/tmp/
ssh saish@pc808.emulab.net 'sudo cp /tmp/ue50.conf /etc/srsue/'

# Verify IP alias 10.10.1.148 exists on pc818
ssh saish@pc818.emulab.net 'ip addr show enp6s0f3 | grep 10.10.1.148'
# If missing:
# ssh saish@pc818.emulab.net 'sudo ip addr add 10.10.1.148/24 dev enp6s0f3'

# Ensure ue50 namespace exists on pc808
ssh saish@pc808.emulab.net 'sudo ip netns add ue50 2>/dev/null || true; ip netns list | grep ue50'
```

---

## Step 2 — Run the ramp experiment

```bash
bash scripts/experiment_ue50_gnb1_ramp.sh saish
```

**What it does:**
1. Kills any stale srsenb/srsue processes for UE50
2. Starts srsenb slot on gnb1 (port 40500)
3. Starts srsue on uehost1 targeting gnb1
4. Waits for attach (~40s), verifies IP and ping
5. Starts `deep_sysmon.py` on gnb1 for the full experiment duration
6. Runs iperf3 DL+UL at **1 → 2 → 5 → 10 → 20 → 50 Mbps** (30s per step)
7. At each step: snapshots gnb1 metrics CSV, UE log, and gnb1 stdout log
8. Parallel ping during each iperf3 step (latency at each throughput level)
9. Final system snapshot (CPU freq, RAPL power, IRQ counts)

**Expected duration:** ~15 minutes

---

## Step 3 — Load-balance UE50 to gnb2

```bash
bash scripts/loadbalance_ue50_to_gnb2.sh saish
```

**What it does:**
1. Drives max DL (50 Mbps) while deep_sysmon runs on gnb1 — **pre-handover baseline**
2. Records `T0` (handover start)
3. `T1` — kills UE50 srsue on uehost1
4. `T2` — kills gnb1 srsenb slot for UE50
5. Sets up gnb2 IP alias `10.10.1.250` and writes `enb_ue50_lb.conf` on pc802
6. `T3` — starts gnb2 srsenb slot (port 60500)
7. Starts deep_sysmon on gnb2 (covers attach + post-HO phase)
8. `T4` — starts UE50 srsue pointing at gnb2
9. `T5` — polls until UE50 attach complete (tun in netns)
10. `T6` — first ping verification
11. Prints handover latency table: T0→T5 (total), T0→T6 (first-packet)
12. Drives max DL 60s on gnb2 — **post-handover baseline at max throughput**
13. Final system snapshot on gnb2 (freq, power, IRQ)

**Key timing outputs** (saved to `/tmp/ran_collect/ue50_lb_transition/handover_timing.txt`):
```
T0_handover_start   → T5_ue_attached_gnb2  =  Total handover latency (ms)
T3_gnb2_slot_start  → T3_gnb2_port_bound   =  gNB2 bind time (ms)
T4_ue_gnb2_start    → T5_ue_attached_gnb2  =  UE re-attach time (ms)
T0                  → T6_first_ping         =  First-packet recovery (ms)
```

---

## Step 4 — Download results

```bash
bash scripts/collect_results_ue50.sh saish
# → creates ./results/ue50_experiment_YYYYMMDD_HHMMSS/
```

---

## Step 5 — Build master CSV

```bash
python3 scripts/build_master_ue50.py ./results/ue50_experiment_YYYYMMDD_HHMMSS/
# → ./results/ue50_experiment_.../master_ue50.csv
```

The master CSV contains **one row per second** with all telemetry merged:

| Column group       | Fields                                                                 |
|--------------------|------------------------------------------------------------------------|
| Identity           | timestamp, phase, ue_id, active_gnb, target_mbps                      |
| RAN / RF           | tti, nof_ues, dl/ul_brate_mbps, dl/ul_mcs, dl/ul_snr_db, dl/ul_bler, phr_db |
| CPU (node)         | user/sys/iowait/irq/softirq/idle %, intr/s, ctxt/s, softIRQ breakdown  |
| CPU (process)      | proc_cpu_user/sys/total_pct, rss_kB, threads, ctxsw/s, schedrun_ns    |
| Memory             | mem_used_MB, load1/5/15                                                |
| Network            | net_rx/tx_bytes_s, net_rx/tx_pkts_s                                    |
| CPU freq & power   | cpu_freq_cur_hz, cpu_power_watts (RAPL)                                |
| Latency            | ping_rtt_min/avg/max/mdev_ms, ping_loss_pct                           |
| Application thput  | iperf_dl/ul_actual_mbps, iperf_dl/ul_retransmits                      |
| Handover markers   | handover_phase (pre/during/post), handover_delta_ms                   |

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| UE50 stuck at "Attaching UE…" | ZMQ deadlock — gnb1 port 40500 not ready before srsue connected | Kill srsue → kill srsenb → restart srsenb → wait 12s → restart srsue |
| `Address already in use: 40500` | Stale srsenb from previous run | `ssh saish@pc818.emulab.net 'sudo pkill -9 srsenb; sleep 5'` |
| gnb2 port 60500 not listening | enb_ue50_lb.conf write failed or srsenb crashed | Check `/tmp/gnb2_logs/ue50_stdout.log` on pc802 |
| UE50 attaches on gnb2 but ping fails | gtp_bind_addr `10.10.1.250` alias missing on pc802 | `ssh saish@pc802.emulab.net 'sudo ip addr add 10.10.1.250/24 dev enp6s0f3'` |
| iperf3 fails ("Connection refused") | iperf3 server not running on core | `ssh saish@pc811.emulab.net 'iperf3 -s -B 10.45.0.1 -p 5250 -D'` |
| deep_sysmon.py not found on gnb1 | Script not deployed | The experiment script SCPs it automatically; check SSH key |
| RAPL shows "not available" | d430 node uses Intel Xeon — RAPL may require `sudo modprobe intel_rapl_common` | `ssh saish@pc818.emulab.net 'sudo modprobe intel_rapl_common intel_rapl_msr'` |

---

## Output File Map

```
results/ue50_experiment_<TS>/
├── master_ue50.csv                          ← Final merged dataset (all phases)
├── gnb1_ramp/
│   ├── gnb1_ue50_stdout.log                 ← srsenb stdout for UE50 on gnb1
│   ├── metrics/
│   │   ├── gnb1_ue50_metrics_full.csv       ← Full TTI metrics (1s/row)
│   │   └── gnb1_ue50_step*mbps_*.csv        ← Per-step snapshots
│   ├── sysmon/
│   │   └── deep_gnb1_ue50_ramp.csv          ← Full deep_sysmon dataset
│   ├── iperf/
│   │   ├── ue50_ramp_summary.csv            ← Per-step iperf3 results
│   │   └── ue50_ue_log_step*mbps.txt        ← UE SNR/MCS/RSRP log per step
│   ├── ping/
│   │   └── ue50_gnb1_*mbps_ping.txt         ← RTT at each throughput step
│   └── gnb1_final_snapshot_*.txt            ← CPU freq/power/IRQ snapshot
│
├── lb_transition/
│   ├── handover_timing.txt                  ← T0–T6 timestamps + delta ms
│   ├── gnb1/
│   │   ├── pre_handover_gnb1_sysmon.csv     ← sysmon during pre-HO window
│   │   ├── pre_ho_gnb1_ue50_metrics_tail.csv← Last 30 rows of gnb1 metrics
│   │   ├── pre_ho_ping_gnb1.txt             ← Latency at max load pre-HO
│   │   └── pre_ho_gnb1_system_snapshot.txt  ← CPU/IRQ/power pre-HO
│   └── (timing markers from both nodes)
│
├── gnb2_post/
│   ├── metrics/
│   │   └── gnb2_ue50_metrics_full.csv       ← gnb2 RAN metrics post-HO
│   ├── sysmon/
│   │   └── deep_gnb2_ue50.csv              ← gnb2 sysmon post-HO
│   ├── ping/
│   │   └── ue50_gnb2_max_ping.txt          ← RTT at max load post-HO
│   ├── gnb2_post_ho_system_snapshot.txt    ← CPU/IRQ/power on gnb2
│   └── ue50_gnb2_log_extract.txt           ← UE SNR/RSRP on gnb2
│
└── mme_logs/
    ├── mme_attach_events.txt                ← Attach complete events
    └── mme_tail_500.txt                     ← Last 500 lines of MME log
```

---

## Algorithm Design Notes

The `master_ue50.csv` dataset is structured to train/validate a **CPU power-saving +
load-balancing algorithm** with the following features:

- **Trigger signals:** `node_cpu_total_pct` rising + `dl_brate_mbps` declining →
  signals congestion before handover is needed.
- **Power efficiency metric:** `cpu_power_watts / dl_brate_mbps` — Joules per bit.
  Lower = better. Should improve after LB when gnb1 loses UE50's load.
- **IRQ/softIRQ cost model:** `node_irq_pct + node_softirq_pct` per Mbps — measures
  interrupt overhead as a function of radio activity.
- **IPC proxy:** `proc_schedrun_ns / proc_schedwait_ns` — proxy for
  instructions-per-cycle; drops under memory pressure.
- **Handover timing:** `handover_delta_ms` column marks exact transition window for
  classification (pre / during / post) in supervised models.
- **SNR ↔ MCS correlation:** `dl_snr_db` vs `dl_mcs` traces link adaptation —
  useful for predicting when a UE would benefit from being on a lightly-loaded gNB.
