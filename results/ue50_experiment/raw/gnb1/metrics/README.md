# gnb1 Per-Step Metrics — Data Availability

The per-step TTI-level metrics files are too large for GitHub (322 MB each × 6 steps).

## Files (stored on POWDER gnb1: pc818.emulab.net)

| File | Size | Description |
|------|------|-------------|
| `gnb1_ue50_at_1mbps_042404.csv`  | 322 MB | TTI metrics during 1 Mbps iperf ramp step |
| `gnb1_ue50_at_2mbps_042406.csv`  | 322 MB | TTI metrics during 2 Mbps step |
| `gnb1_ue50_at_5mbps_042407.csv`  | 322 MB | TTI metrics during 5 Mbps step |
| `gnb1_ue50_at_10mbps_042408.csv` | 322 MB | TTI metrics during 10 Mbps step |
| `gnb1_ue50_at_20mbps_042409.csv` | 322 MB | TTI metrics during 20 Mbps step |
| `gnb1_ue50_at_50mbps_042410.csv` | 322 MB | TTI metrics during 50 Mbps step |

## Format (semicolon-delimited, header on line 1)

```
time;nof_ue;dl_brate;ul_brate;proc_rmem;proc_rmem_kB;proc_vmem_kB;sys_mem;system_load;thread_count;cpu_0;cpu_1;...;cpu_31
```

- `time`: TTI index (0–2,314,545 = 2314 seconds total)
- `dl_brate` / `ul_brate`: always 0.0 in ZMQ mode — use iperf JSON for actual throughput
- `cpu_0..cpu_31`: per-core CPU % (32 cores)

## Retrieve from POWDER

```bash
scp saish@pc818.emulab.net:/tmp/ran_collect/ue50_gnb1/metrics/gnb1_ue50_at_*mbps_*.csv ./

# Use the pre-sampled version in this repo instead (every 5000 TTIs):
# results/ue50_experiment/gnb_metrics_sampled.csv
```
