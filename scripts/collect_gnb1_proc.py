#!/usr/bin/env python3
"""
collect_gnb1_proc.py
────────────────────
Collects live proc metrics for all running srsenb processes on gnb1.
Samples each process 10 times at 1s intervals, computes mean.
Writes /tmp/ran_collect/gnb1_proc_metrics.csv

Columns: ue_id, pid, proc_rss_kB, proc_vmem_kB, proc_cpu_pct,
         sys_mem_pct, sys_load, thread_count,
         dl_brate_bps, ul_brate_bps
"""

import subprocess, csv, re, time, os
from pathlib import Path
from statistics import mean

OUT = Path("/tmp/ran_collect/gnb1_proc_metrics.csv")
SAMPLE_N   = 10
SAMPLE_INT = 1.0   # seconds between samples
LOG_DIR    = Path("/tmp/gnb1_logs")

def get_procs():
    """Return dict: ue_id -> pid by scanning srsenb process names / cmdlines."""
    out = subprocess.check_output(
        ["ps", "aux"], text=True, errors="replace"
    )
    procs = {}
    for line in out.splitlines():
        # srsenb processes named like "srsenb" with config containing ue_id hint
        # Match: saish  <pid> ... srsenb --rf.device_name=zmq
        if "srsenb" not in line:
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        pid = int(parts[1])
        # Try to identify ue_id from config file path: enb_ueN.conf
        cmd_match = re.search(r'enb_ue(\d+)\.conf', line)
        if cmd_match:
            uid = int(cmd_match.group(1))
            procs[uid] = pid
    return procs

def read_proc_stats(pid):
    """Read /proc/<pid>/status and /proc/<pid>/stat for a process."""
    data = {}
    try:
        status = open(f"/proc/{pid}/status", errors="replace").read()
        m = re.search(r'VmRSS:\s+(\d+)', status)
        if m: data["rss_kB"] = int(m.group(1))
        m = re.search(r'VmSize:\s+(\d+)', status)
        if m: data["vmem_kB"] = int(m.group(1))
        m = re.search(r'Threads:\s+(\d+)', status)
        if m: data["threads"] = int(m.group(1))
    except Exception:
        pass

    try:
        stat = open(f"/proc/{pid}/stat", errors="replace").read().split()
        # utime=14, stime=15 (ticks), convert using HZ=100
        utime = int(stat[13]); stime = int(stat[14])
        data["jiffies"] = utime + stime
        data["uptime"]  = float(open("/proc/uptime").read().split()[0])
    except Exception:
        pass

    return data

def read_sys_stats():
    """Read system-level memory and load."""
    data = {}
    try:
        meminfo = open("/proc/meminfo", errors="replace").read()
        total = int(re.search(r'MemTotal:\s+(\d+)', meminfo).group(1))
        avail = int(re.search(r'MemAvailable:\s+(\d+)', meminfo).group(1))
        data["sys_mem_pct"] = round((total - avail) / total * 100, 2)
    except Exception:
        pass
    try:
        loadavg = open("/proc/loadavg").read().split()
        data["sys_load"] = float(loadavg[0])
    except Exception:
        pass
    return data

def read_brate_from_log(uid):
    """
    Parse the last dl/ul brate from srsenb stdout log for this UE slot.
    Line format: "STATS: <timestamp> ... dl_brate=XXXXXX.X bps ul_brate=XXXXXX.X bps"
    or from the gnb_gnb1.csv sysmon.
    """
    # Try per-UE metrics CSV first
    mfile = Path(f"/tmp/gnb1_ue{uid}_metrics.csv")
    if mfile.exists():
        try:
            rows = list(csv.DictReader(open(mfile, errors="replace")))
            dl_vals = [float(r["dl_brate_bps"]) for r in rows
                       if r.get("dl_brate_bps", "") not in ("", "NA", "nan")]
            ul_vals = [float(r["ul_brate_bps"]) for r in rows
                       if r.get("ul_brate_bps", "") not in ("", "NA", "nan")]
            dl = round(mean(dl_vals), 2) if dl_vals else None
            ul = round(mean(ul_vals), 2) if ul_vals else None
            return dl, ul
        except Exception:
            pass

    # Try stdout log
    stdout = LOG_DIR / f"ue{uid}_stdout.log"
    if stdout.exists():
        try:
            with open(stdout, errors="replace") as f:
                lines = f.readlines()
            tail = lines[-200:]
            dl_vals, ul_vals = [], []
            for line in tail:
                m = re.search(r'dl_brate\s*[=:]\s*([\d.]+)', line, re.IGNORECASE)
                if m: dl_vals.append(float(m.group(1)))
                m = re.search(r'ul_brate\s*[=:]\s*([\d.]+)', line, re.IGNORECASE)
                if m: ul_vals.append(float(m.group(1)))
            dl = round(mean(dl_vals), 2) if dl_vals else None
            ul = round(mean(ul_vals), 2) if ul_vals else None
            if dl is not None or ul is not None:
                return dl, ul
        except Exception:
            pass

    return None, None

# ── Main ───────────────────────────────────────────────────────────────────────
print("Finding srsenb processes ...")
procs = get_procs()
print(f"  Found {len(procs)} srsenb processes: {sorted(procs.keys())[:10]}...")

if not procs:
    print("ERROR: no srsenb processes found — are they still running?")
    exit(1)

sys_stats = read_sys_stats()
print(f"  System: mem={sys_stats.get('sys_mem_pct','?')}%  load={sys_stats.get('sys_load','?')}")

# Sample CPU usage for each process (delta jiffies / delta time)
print(f"Sampling {SAMPLE_N}x at {SAMPLE_INT}s intervals ...")
samples = {uid: [] for uid in procs}
prev    = {}

for uid, pid in procs.items():
    s = read_proc_stats(pid)
    prev[uid] = s

time.sleep(SAMPLE_INT)

for sample_i in range(SAMPLE_N):
    for uid, pid in procs.items():
        cur = read_proc_stats(pid)
        if "jiffies" in cur and "jiffies" in prev.get(uid, {}):
            delta_j = cur["jiffies"] - prev[uid]["jiffies"]
            delta_t = (cur.get("uptime", 0) - prev[uid].get("uptime", 0))
            cpu_pct = round(delta_j / max(delta_t, 0.001) / 100 * 100, 2) if delta_t > 0 else 0
            samples[uid].append({
                "rss_kB":   cur.get("rss_kB",   prev[uid].get("rss_kB",   0)),
                "vmem_kB":  cur.get("vmem_kB",  prev[uid].get("vmem_kB",  0)),
                "threads":  cur.get("threads",  prev[uid].get("threads",  0)),
                "cpu_pct":  cpu_pct,
            })
        prev[uid] = cur
    if sample_i < SAMPLE_N - 1:
        time.sleep(SAMPLE_INT)

print("Writing output ...")
FIELDS = ["ue_id", "pid", "proc_rss_kB", "proc_vmem_kB", "proc_cpu_pct",
          "thread_count", "sys_mem_pct", "sys_load", "dl_brate_bps", "ul_brate_bps"]

rows = []
for uid in sorted(procs.keys()):
    pid = procs[uid]
    s   = samples[uid]
    dl, ul = read_brate_from_log(uid)
    row = {
        "ue_id":       uid,
        "pid":         pid,
        "proc_rss_kB": round(mean([x["rss_kB"]  for x in s]), 0) if s else "",
        "proc_vmem_kB":round(mean([x["vmem_kB"] for x in s]), 0) if s else "",
        "proc_cpu_pct":round(mean([x["cpu_pct"] for x in s]), 2) if s else "",
        "thread_count":round(mean([x["threads"] for x in s]), 0) if s else "",
        "sys_mem_pct": sys_stats.get("sys_mem_pct", ""),
        "sys_load":    sys_stats.get("sys_load",    ""),
        "dl_brate_bps":dl if dl is not None else "",
        "ul_brate_bps":ul if ul is not None else "",
    }
    rows.append(row)
    print(f"  UE{uid:3d} pid={pid}  rss={row['proc_rss_kB']} kB  cpu={row['proc_cpu_pct']}%  dl={dl}  ul={ul}")

with open(OUT, "w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=FIELDS)
    writer.writeheader()
    writer.writerows(rows)

print(f"\nSaved {len(rows)} rows → {OUT}")
