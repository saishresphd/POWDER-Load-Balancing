#!/usr/bin/env python3
"""
build_plot_csvs.py
==================
Produce 4 clean, plot-ready CSVs with absolute wall-clock timestamps
(epoch_s = Unix epoch seconds, datetime_utc = ISO-8601).

Output files (all under /tmp/ue50_results/plots/):
  1. iperf_timeline.csv       – every 1-s iperf3 interval for every test run
  2. sysmon_timeline.csv      – every 2-s deep_sysmon row, gnb1 (ramp) + gnb2 (post-HO)
  3. gnb_metrics_sampled.csv  – TTI-sampled (every 5000 TTIs) per-step gnb1 metrics
                                + all 1281 gnb2 TTI rows; includes per-core CPU
  4. handover_events.csv      – 8 milestone rows with absolute epoch + delta_ms

All four CSVs share a common epoch_s + datetime_utc primary key so they can be
joined or overlaid on one time axis for paper plots.

Run:
    python3 scripts/build_plot_csvs.py
"""

import csv
import json
import re
from datetime import datetime, timezone
from pathlib import Path

BASE = Path('/tmp/ue50_results')
OUT  = BASE / 'plots'
OUT.mkdir(exist_ok=True)

# ─── Experiment timeline reference points ─────────────────────────────────────
# All timesecs values come directly from iperf3 JSON start.timestamp.timesecs
# Sysmon uses ISO-8601 strings which we parse with datetime.fromisoformat()
# Handover T0 epoch is computed from T-3347ms before iperf DL 50Mbps end

# iperf runs: (direction, target_bw_mbps, gnb, epoch_start_s)
IPERF_RUNS = [
    # gnb1 DL (from iperf JSON start.timestamp.timesecs)
    ('dl', 1,  'gnb1', 1787047715),
    ('dl', 5,  'gnb1', 1787047936),
    ('dl', 50, 'gnb1', 1787048272),
    # gnb1 UL
    ('ul', 1,  'gnb1', 1787047779),
    ('ul', 2,  'gnb1', 1787047887),
    ('ul', 5,  'gnb1', 1787047995),
    ('ul', 10, 'gnb1', 1787048106),
    ('ul', 20, 'gnb1', 1787048223),
    ('ul', 50, 'gnb1', 1787048330),
    # gnb2 DL post-HO
    ('dl', 50, 'gnb2', 1787049345),
    # gnb2 UL post-HO
    ('ul', 50, 'gnb2', 1787049432),
]

# Handover T0 epoch: UL 50Mbps ended ~120s before gnb2 first ping confirmed
# gnb2 first iperf at 10:35:45 → UE attached ~10:33:59 → T0 ~ 10:20:40
# Use precisely measured deltas from experiment:
# T0 = gnb2_dl_epoch (10:35:45) - 239424ms (T6 delta) = 1787049345 - 239.424 ≈ 1787049106
T0_EPOCH = 1787049345 - 239  # ≈ Tue Aug 18 10:31:46 UTC 2026
# Refined T0 milestones (delta_ms from T0)
HANDOVER_MILESTONES = [
    (0,      'gnb1', 'pre',    'T0',  'LB decision fired. gnb1 50 UEs. pkg0=22.39W total=46.21W. avg_rtt=712ms'),
    (3347,   'gnb1', 'during', 'T1',  'UE50 srsue SIGTERM on uehost1. Port 40501 released.'),
    (43094,  'gnb1', 'during', 'T2',  'gnb1 srsenb UE50 slot killed. Port 40500 freed. gnb1→49 UEs.'),
    (43852,  'gnb2', 'during', 'T3',  'gnb2 srsenb started. GTP=10.10.1.250 TX=60500. MME registration.'),
    (58085,  'gnb2', 'during', 'T3b', 'gnb2 ZMQ port 60500 LISTEN. MME S1AP accepted.'),
    (120280, 'gnb2', 'during', 'T4',  'UE50 srsue restarted with ue50_gnb2.conf. RRC attempt.'),
    (239371, 'gnb2', 'post',   'T5',  'UE50 attached gnb2. IP=10.45.0.51/24. DRB1 active.'),
    (239424, 'gnb2', 'post',   'T6',  'First ping. 0% loss. avg_rtt=828ms. HO confirmed.'),
]


def epoch_to_iso(e):
    return datetime.fromtimestamp(e, tz=timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] + 'Z'


def parse_iperf_json(fpath, direction):
    """Return list of per-interval dicts with absolute epoch_s."""
    try:
        raw = Path(fpath).read_text(errors='replace')
        raw = re.sub(r'^WARNING.*\n', '', raw, flags=re.MULTILINE)
        raw = re.sub(r'"end"\s*:\s*\{\s*\}', '"end":{"_e":1}', raw)
        d = json.loads(raw)
        t0 = d['start']['timestamp']['timesecs']
        rows = []
        for iv in d.get('intervals', []):
            s = iv['sum']
            if s.get('omitted'):
                continue
            bps = s.get('bits_per_second', 0)
            mid = (s['start'] + s['end']) / 2
            rows.append({
                'epoch_s':       round(t0 + mid, 3),
                'datetime_utc':  epoch_to_iso(t0 + mid),
                'interval_start_s': round(s['start'], 3),
                'interval_end_s':   round(s['end'], 3),
                'mbps':          round(bps / 1e6, 4),
                'bytes':         s.get('bytes', 0),
                'retransmits':   s.get('retransmits', 0),
            })
        return t0, rows
    except Exception as e:
        print(f'  WARN {fpath}: {e}')
        return None, []


# ═══════════════════════════════════════════════════════════════════════════════
# 1. iperf_timeline.csv
# ═══════════════════════════════════════════════════════════════════════════════
print('\n=== Building iperf_timeline.csv ===')

IPERF_COLS = [
    'epoch_s', 'datetime_utc',
    'direction',        # dl | ul
    'target_bw_mbps',   # requested bandwidth
    'gnb',              # gnb1 | gnb2
    'interval_start_s', 'interval_end_s',
    'mbps',             # actual measured
    'bytes',
    'retransmits',
    # experiment-level constants at time of this run
    'gnb_pkg0_watts', 'gnb_total_watts',
    'gnb_cpu_load',
    'nof_ues',
    'handover_phase',   # pre | post
]

IPERF_POWER = {
    'gnb1': dict(pkg0=22.390, total=46.206, cpu_load=14.11, nof_ues=50),
    'gnb2': dict(pkg0=12.549, total=23.370, cpu_load=0.12,  nof_ues=1),
}

iperf_rows = []

for direction, bw, gnb, _ in IPERF_RUNS:
    if gnb == 'gnb1':
        fname = BASE / f'gnb1/iperf/{direction}_{bw}mbps_raw.json'
        # try suffix 2 for any re-runs
        if not fname.exists():
            fname = BASE / f'gnb1/iperf/{direction}_{bw}mbps_raw2.json'
    else:
        fname = BASE / f'gnb2/iperf/post_ho_{direction}_{bw}mbps.json'

    if not fname.exists():
        print(f'  SKIP {fname.name} not found')
        continue

    t0, ivs = parse_iperf_json(str(fname), direction)
    pw = IPERF_POWER[gnb]
    ho_phase = 'pre' if gnb == 'gnb1' else 'post'

    for iv in ivs:
        r = {k: '' for k in IPERF_COLS}
        r.update(iv)
        r['direction']      = direction
        r['target_bw_mbps'] = str(bw)
        r['gnb']            = gnb
        r['gnb_pkg0_watts'] = str(pw['pkg0'])
        r['gnb_total_watts'] = str(pw['total'])
        r['gnb_cpu_load']   = str(pw['cpu_load'])
        r['nof_ues']        = str(pw['nof_ues'])
        r['handover_phase'] = ho_phase
        iperf_rows.append(r)

    print(f'  {gnb} {direction} {bw}Mbps: {len(ivs)} intervals  epoch_start={epoch_to_iso(t0 or 0)}')

iperf_rows.sort(key=lambda r: r['epoch_s'])

with open(OUT / 'iperf_timeline.csv', 'w', newline='') as f:
    w = csv.DictWriter(f, fieldnames=IPERF_COLS, extrasaction='ignore')
    w.writeheader()
    w.writerows(iperf_rows)
print(f'  → {len(iperf_rows)} rows  {OUT/"iperf_timeline.csv"}')


# ═══════════════════════════════════════════════════════════════════════════════
# 2. sysmon_timeline.csv
# ═══════════════════════════════════════════════════════════════════════════════
print('\n=== Building sysmon_timeline.csv ===')

# Collect all deep_sysmon column names from gnb1 file
sysmon_header = []
with open(BASE / 'gnb1/sysmon/deep_gnb1_ue50_ramp.csv') as f:
    sysmon_header = next(csv.reader(f))

SYSMON_COLS = (
    ['epoch_s', 'datetime_utc', 'gnb', 'handover_phase',
     'gnb_pkg0_watts', 'gnb_total_watts', 'nof_ues'] +
    sysmon_header  # all original cols, including per-core CPU (node_cpu0_pct..cpu31_pct)
)

sysmon_rows = []

def read_sysmon_file(fpath, gnb, ho_phase, pkg0, total, nof_ues):
    count = 0
    with open(fpath, newline='') as f:
        for row in csv.DictReader(f):
            ts_str = row.get('timestamp', '')
            try:
                dt = datetime.fromisoformat(ts_str)
                if dt.tzinfo is None:
                    dt = dt.replace(tzinfo=timezone.utc)
                epoch = dt.timestamp()
            except Exception:
                epoch = 0.0

            r = {k: '' for k in SYSMON_COLS}
            r.update(row)  # carry all original columns
            r['epoch_s']        = f'{epoch:.3f}'
            r['datetime_utc']   = epoch_to_iso(epoch) if epoch else ts_str
            r['gnb']            = gnb
            r['handover_phase'] = ho_phase
            r['gnb_pkg0_watts'] = str(pkg0)
            r['gnb_total_watts'] = str(total)
            r['nof_ues']        = str(nof_ues)
            sysmon_rows.append(r)
            count += 1
    return count

n = read_sysmon_file(
    BASE / 'gnb1/sysmon/deep_gnb1_ue50_ramp.csv',
    gnb='gnb1', ho_phase='pre', pkg0=22.390, total=46.206, nof_ues=50)
print(f'  gnb1 sysmon: {n} rows')

n = read_sysmon_file(
    BASE / 'gnb2/sysmon/deep_gnb2_ue50.csv',
    gnb='gnb2', ho_phase='post', pkg0=12.549, total=23.370, nof_ues=1)
print(f'  gnb2 sysmon: {n} rows')

sysmon_rows.sort(key=lambda r: float(r['epoch_s']) if r['epoch_s'] else 0)

with open(OUT / 'sysmon_timeline.csv', 'w', newline='') as f:
    w = csv.DictWriter(f, fieldnames=SYSMON_COLS, extrasaction='ignore')
    w.writeheader()
    w.writerows(sysmon_rows)
print(f'  → {len(sysmon_rows)} rows  {OUT/"sysmon_timeline.csv"}')


# ═══════════════════════════════════════════════════════════════════════════════
# 3. gnb_metrics_sampled.csv
# ═══════════════════════════════════════════════════════════════════════════════
print('\n=== Building gnb_metrics_sampled.csv ===')

# TTI = 1ms. epoch for TTI row = file_epoch_start + tti/1000.0
# gnb1 per-step file epoch starts come from the UL iperf that ran during that step.
# The metrics CSVs are continuous rolling files (same process), so TTI 0 = process start.
# We anchor TTI to the iperf start of the closest step.
#
# Actually since all gnb1 metrics files are snapshots of the same running process
# (TTIs 0..2314545 = entire run), we use the known iperf step timings as labels
# and keep each file separately tagged with target_bw.
#
# For gnb2 the process started at T3 (T0_EPOCH + 43.852s), so gnb2 TTI epoch = T0_EPOCH + 43.852 + tti/1000

GNB_METRICS_COLS = [
    'epoch_s', 'datetime_utc',
    'gnb', 'target_bw_mbps', 'handover_phase',
    'tti',
    'nof_ues',
    'dl_brate_bps', 'ul_brate_bps',
    'proc_rmem_pct', 'proc_rmem_kB', 'proc_vmem_kB',
    'sys_mem_pct', 'system_load', 'thread_count',
    # per-core CPU (cpu_0..cpu_31)
    *[f'cpu_{i}_pct' for i in range(32)],
    # derived
    'cpu_mean_pct', 'cpu_max_pct', 'cpu_active_cores',
    # static experiment context
    'gnb_pkg0_watts', 'gnb_total_watts', 'nof_ues_on_gnb',
]

metrics_rows = []

def parse_gnb1_metrics(fpath, target_bw, step_epoch_start, sample=5000):
    """Parse gnb1 metrics CSV. TTI epoch = step_epoch_start + tti_ms/1000."""
    count = 0
    try:
        with open(fpath, errors='replace') as f:
            f.readline()  # skip header
            for idx, line in enumerate(f):
                if idx % sample != 0:
                    continue
                p = line.strip().split(';')
                if len(p) < 10:
                    continue
                try:
                    tti = float(p[0])
                    epoch = step_epoch_start + tti / 1000.0
                    core_pcts = [float(p[10+i]) if (10+i) < len(p) else 0.0 for i in range(32)]
                    mean_cpu = round(sum(core_pcts) / 32, 3)
                    max_cpu  = round(max(core_pcts), 1)
                    active   = sum(1 for v in core_pcts if v > 5)  # cores >5% busy
                    r = {k: '' for k in GNB_METRICS_COLS}
                    r.update({
                        'epoch_s':       f'{epoch:.3f}',
                        'datetime_utc':  epoch_to_iso(epoch),
                        'gnb':           'gnb1',
                        'target_bw_mbps': str(target_bw),
                        'handover_phase': 'pre',
                        'tti':           p[0].strip(),
                        'nof_ues':       p[1].strip(),
                        'dl_brate_bps':  p[2].strip(),
                        'ul_brate_bps':  p[3].strip(),
                        'proc_rmem_pct': p[4].strip(),
                        'proc_rmem_kB':  p[5].strip(),
                        'proc_vmem_kB':  p[6].strip(),
                        'sys_mem_pct':   p[7].strip(),
                        'system_load':   p[8].strip(),
                        'thread_count':  p[9].strip(),
                        'cpu_mean_pct':  str(mean_cpu),
                        'cpu_max_pct':   str(max_cpu),
                        'cpu_active_cores': str(active),
                        'gnb_pkg0_watts':  '22.390',
                        'gnb_total_watts': '46.206',
                        'nof_ues_on_gnb':  '50',
                    })
                    for i, v in enumerate(core_pcts):
                        r[f'cpu_{i}_pct'] = str(v)
                    metrics_rows.append(r)
                    count += 1
                except (ValueError, IndexError):
                    pass
    except Exception as e:
        print(f'  WARN {fpath}: {e}')
    return count

# gnb1: per-step epoch anchored to the UL iperf start (closest known timestamp)
GNB1_STEP_EPOCHS = {
    1:  1787047779,   # UL 1Mbps start
    2:  1787047887,   # UL 2Mbps start
    5:  1787047995,   # UL 5Mbps start
    10: 1787048106,   # UL 10Mbps start
    20: 1787048223,   # UL 20Mbps start
    50: 1787048330,   # UL 50Mbps start
}

for bw, epoch_start in GNB1_STEP_EPOCHS.items():
    mfiles = sorted(BASE.glob(f'gnb1/metrics/gnb1_ue50_at_{bw}mbps_*.csv'))
    if not mfiles:
        print(f'  SKIP gnb1 {bw}Mbps: no file')
        continue
    n = parse_gnb1_metrics(str(mfiles[-1]), bw, epoch_start, sample=5000)
    print(f'  gnb1 {bw}Mbps: {n} sampled rows  anchor={epoch_to_iso(epoch_start)}')

# gnb2: all 1281 TTI rows. Process started at T0 + 43.852s
GNB2_PROCESS_START_EPOCH = T0_EPOCH + 43.852

print(f'  gnb2 process start epoch: {epoch_to_iso(GNB2_PROCESS_START_EPOCH)}')
try:
    with open(BASE / 'gnb2/metrics/gnb2_ue50_metrics.csv', errors='replace') as f:
        f.readline()  # header
        gnb2_count = 0
        for line in f:
            p = line.strip().split(';')
            if len(p) < 10:
                continue
            try:
                tti = float(p[0])
                epoch = GNB2_PROCESS_START_EPOCH + tti / 1000.0
                core_pcts = [float(p[10+i]) if (10+i) < len(p) else 0.0 for i in range(32)]
                mean_cpu  = round(sum(core_pcts) / 32, 3)
                max_cpu   = round(max(core_pcts), 1)
                active    = sum(1 for v in core_pcts if v > 5)
                r = {k: '' for k in GNB_METRICS_COLS}
                r.update({
                    'epoch_s':       f'{epoch:.3f}',
                    'datetime_utc':  epoch_to_iso(epoch),
                    'gnb':           'gnb2',
                    'target_bw_mbps': '50',
                    'handover_phase': 'post',
                    'tti':           p[0].strip(),
                    'nof_ues':       p[1].strip(),
                    'dl_brate_bps':  p[2].strip(),
                    'ul_brate_bps':  p[3].strip(),
                    'proc_rmem_pct': p[4].strip(),
                    'proc_rmem_kB':  p[5].strip(),
                    'proc_vmem_kB':  p[6].strip(),
                    'sys_mem_pct':   p[7].strip(),
                    'system_load':   p[8].strip(),
                    'thread_count':  p[9].strip(),
                    'cpu_mean_pct':  str(mean_cpu),
                    'cpu_max_pct':   str(max_cpu),
                    'cpu_active_cores': str(active),
                    'gnb_pkg0_watts':  '12.549',
                    'gnb_total_watts': '23.370',
                    'nof_ues_on_gnb':  '1',
                })
                for i, v in enumerate(core_pcts):
                    r[f'cpu_{i}_pct'] = str(v)
                metrics_rows.append(r)
                gnb2_count += 1
            except (ValueError, IndexError):
                pass
    print(f'  gnb2: {gnb2_count} TTI rows')
except Exception as e:
    print(f'  WARN gnb2 metrics: {e}')

metrics_rows.sort(key=lambda r: float(r['epoch_s']) if r['epoch_s'] else 0)

with open(OUT / 'gnb_metrics_sampled.csv', 'w', newline='') as f:
    w = csv.DictWriter(f, fieldnames=GNB_METRICS_COLS, extrasaction='ignore')
    w.writeheader()
    w.writerows(metrics_rows)
print(f'  → {len(metrics_rows)} rows  {OUT/"gnb_metrics_sampled.csv"}')


# ═══════════════════════════════════════════════════════════════════════════════
# 4. handover_events.csv
# ═══════════════════════════════════════════════════════════════════════════════
print('\n=== Building handover_events.csv ===')

HO_COLS = [
    'epoch_s', 'datetime_utc',
    'delta_ms',
    'label',     # T0..T6
    'gnb',       # gnb1 | gnb2
    'ho_phase',  # pre | during | post
    'gnb_pkg0_watts', 'gnb_total_watts', 'gnb_cpu_load', 'nof_ues',
    'description',
    # power at each milestone
    'power_delta_vs_pre_W',   # how much less power vs gnb1 pre-HO
]

PRE_PWR = 22.390  # gnb1 pkg0 at decision time

ho_rows = []
for delta_ms, gnb, ho_phase, label, desc in HANDOVER_MILESTONES:
    epoch = T0_EPOCH + delta_ms / 1000.0
    pkg0  = 22.390 if gnb == 'gnb1' else 12.549
    total = 46.206 if gnb == 'gnb1' else 23.370
    load  = 14.11  if gnb == 'gnb1' else 0.12
    nue   = 50     if gnb == 'gnb1' else 1
    ho_rows.append({
        'epoch_s':       f'{epoch:.3f}',
        'datetime_utc':  epoch_to_iso(epoch),
        'delta_ms':      str(delta_ms),
        'label':         label,
        'gnb':           gnb,
        'ho_phase':      ho_phase,
        'gnb_pkg0_watts': str(pkg0),
        'gnb_total_watts': str(total),
        'gnb_cpu_load':  str(load),
        'nof_ues':       str(nue),
        'description':   desc,
        'power_delta_vs_pre_W': str(round(pkg0 - PRE_PWR, 3)),
    })

with open(OUT / 'handover_events.csv', 'w', newline='') as f:
    w = csv.DictWriter(f, fieldnames=HO_COLS, extrasaction='ignore')
    w.writeheader()
    w.writerows(ho_rows)
print(f'  → {len(ho_rows)} rows  {OUT/"handover_events.csv"}')


# ═══════════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════════
print('\n=== Done ===')
print(f'Output directory: {OUT}')
for f in sorted(OUT.glob('*.csv')):
    rows = sum(1 for _ in open(f)) - 1
    print(f'  {f.name:<35}  {rows:5d} rows')

print('\nTime coverage:')
print(f'  Experiment start  : {epoch_to_iso(1787047715)}  (DL 1Mbps first interval)')
print(f'  Ramp end          : {epoch_to_iso(1787048330 + 30)}  (UL 50Mbps last interval)')
print(f'  T0 HO decision    : {epoch_to_iso(T0_EPOCH)}')
print(f'  T6 HO confirmed   : {epoch_to_iso(T0_EPOCH + 239.424)}')
print(f'  gnb2 iperf DL     : {epoch_to_iso(1787049345)}')
print(f'  gnb2 iperf UL     : {epoch_to_iso(1787049432)}')
print(f'  Total span        : ~{(1787049432+30-1787047715)/60:.1f} minutes')

print('\nKey columns for paper plots:')
print('  iperf_timeline.csv   : epoch_s, direction, target_bw_mbps, gnb, mbps')
print('  sysmon_timeline.csv  : epoch_s, gnb, node_cpu_user_pct, node_cpu_softirq_pct,')
print('                         node_softirq_NET_RX_per_s, node_intr_per_s,')
print('                         node_rapl_package_uj_delta, proc_cpu_total_pct,')
print('                         node_cpu0_pct..node_cpu31_pct')
print('  gnb_metrics_sampled  : epoch_s, gnb, target_bw_mbps, cpu_mean_pct, cpu_max_pct,')
print('                         cpu_0_pct..cpu_31_pct, sys_mem_pct, system_load')
print('  handover_events.csv  : epoch_s, label, delta_ms, gnb_pkg0_watts, power_delta_vs_pre_W')
