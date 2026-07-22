#!/usr/bin/env python3
"""
deep_sysmon.py  —  Comprehensive system + per-process metrics collector
Polls every INTERVAL seconds for DURATION seconds.
Collects:
  Node-level:
    - Per-core CPU %  (cpu0..cpu31 from /proc/stat delta)
    - CPU total user/system/iowait/irq/softirq/idle %
    - RAM: total, used, free, buffers, cached, avail (MB)
    - Swap used (MB)
    - Load avg 1/5/15
    - Context switches/s (voluntary + nonvoluntary from sum of all tracked pids)
    - Interrupts/s (total from /proc/stat intr line delta)
    - Softirq breakdown: NET_RX, NET_TX, TIMER, SCHED, TASKLET, RCU rates/s
    - Network: rx_bytes/s, tx_bytes/s, rx_pkts/s, tx_pkts/s, rx_drop, tx_drop
    - CPU temperatures: package0_C, package1_C, core_max_C (from hwmon)
  Per-process (tracked PIDs = srsenb or srsue depending on node):
    - pid, name, cpu_user_pct, cpu_sys_pct, cpu_ipc_proxy (utime delta / hz)
    - rss_kB, vsz_kB, vmlock_kB (from /proc/pid/status)
    - threads, voluntary_ctxsw_s, nonvol_ctxsw_s
    - schedstat: run_time_ns, wait_time_ns, run_count (from /proc/pid/schedstat)
    - open_fds (count of /proc/pid/fd/*)

Usage:
  python3 deep_sysmon.py [duration_s] [interval_s] [proc_filter] [output_csv]
  python3 deep_sysmon.py 300 5 srsenb /tmp/ran_collect/deep_gnb1.csv
  python3 deep_sysmon.py 300 5 srsue   /tmp/ran_collect/deep_uehost1.csv
"""

import sys, os, time, csv, re, glob
from pathlib import Path

DURATION   = int(sys.argv[1])   if len(sys.argv) > 1 else 300
INTERVAL   = int(sys.argv[2])   if len(sys.argv) > 2 else 5
PROC_FILTER = sys.argv[3]       if len(sys.argv) > 3 else "srsenb"
OUT_FILE    = sys.argv[4]       if len(sys.argv) > 4 else f"/tmp/ran_collect/deep_{PROC_FILTER}.csv"

HZ = os.sysconf(os.sysconf_names['SC_CLK_TCK'])
PAGESIZE = os.sysconf(os.sysconf_names['SC_PAGESIZE'])

# ── Helpers ───────────────────────────────────────────────────────────────────

def read_file(p):
    try:
        return Path(p).read_text(errors="replace")
    except Exception:
        return ""

def read_int(p):
    try:
        return int(Path(p).read_text().strip())
    except Exception:
        return 0

def get_procs(name_filter):
    """Return list of (pid, cmdline) matching name_filter."""
    procs = []
    for p in Path("/proc").iterdir():
        if not p.name.isdigit():
            continue
        try:
            cmd = (p / "cmdline").read_text().replace("\x00", " ").strip()
            if name_filter in cmd:
                procs.append((int(p.name), cmd[:80]))
        except Exception:
            pass
    return sorted(procs)

def parse_proc_stat(pid):
    """Return (utime, stime) ticks from /proc/pid/stat."""
    try:
        fields = read_file(f"/proc/{pid}/stat").split()
        if len(fields) >= 15:
            return int(fields[13]), int(fields[14])
    except Exception:
        pass
    return 0, 0

def parse_schedstat(pid):
    """Return (run_time_ns, wait_time_ns, run_count)."""
    try:
        parts = read_file(f"/proc/{pid}/schedstat").split()
        if len(parts) >= 3:
            return int(parts[0]), int(parts[1]), int(parts[2])
    except Exception:
        pass
    return 0, 0, 0

def parse_status(pid):
    """Return dict of key fields from /proc/pid/status."""
    result = {}
    for line in read_file(f"/proc/{pid}/status").splitlines():
        if ":" in line:
            k, _, v = line.partition(":")
            result[k.strip()] = v.strip()
    return result

def count_fds(pid):
    try:
        return len(list(Path(f"/proc/{pid}/fd").iterdir()))
    except Exception:
        return -1

def parse_cpu_stat():
    """Parse /proc/stat → dict per cpu: [user,nice,sys,idle,iowait,irq,softirq,steal]."""
    result = {}
    intr_total = 0
    ctxt = 0
    for line in read_file("/proc/stat").splitlines():
        if line.startswith("cpu"):
            parts = line.split()
            key = parts[0]
            vals = list(map(int, parts[1:9]))  # user nice sys idle iowait irq softirq steal
            result[key] = vals
        elif line.startswith("intr "):
            intr_total = int(line.split()[1])
        elif line.startswith("ctxt "):
            ctxt = int(line.split()[1])
    return result, intr_total, ctxt

def cpu_pct(prev, curr):
    """Compute % from two snapshots (list of 8 ints)."""
    total_prev = sum(prev)
    total_curr = sum(curr)
    delta_total = total_curr - total_prev
    if delta_total <= 0:
        return {k: 0.0 for k in ["user","sys","iowait","irq","softirq","idle"]}
    def pct(idx_or_idxs):
        if isinstance(idx_or_idxs, list):
            d = sum(curr[i]-prev[i] for i in idx_or_idxs)
        else:
            d = curr[idx_or_idxs] - prev[idx_or_idxs]
        return round(100.0 * d / delta_total, 2)
    return {
        "user":    pct(0),
        "sys":     pct(2),
        "iowait":  pct(4),
        "irq":     pct(5),
        "softirq": pct(6),
        "idle":    pct(3),
    }

def parse_softirqs():
    """Return dict of softirq name → total across all CPUs."""
    result = {}
    for line in read_file("/proc/softirqs").splitlines():
        parts = line.split()
        if len(parts) > 1 and parts[0].endswith(":"):
            name = parts[0].rstrip(":")
            result[name] = sum(int(x) for x in parts[1:] if x.isdigit())
    return result

def parse_meminfo():
    """Return dict of key meminfo fields in MB."""
    result = {}
    for line in read_file("/proc/meminfo").splitlines():
        k, _, v = line.partition(":")
        try:
            kb = int(v.strip().split()[0])
            result[k.strip()] = round(kb / 1024, 1)
        except Exception:
            pass
    return result

def parse_net_dev(iface):
    """Return (rx_bytes, tx_bytes, rx_pkts, tx_pkts, rx_drop, tx_drop) for iface."""
    for line in read_file("/proc/net/dev").splitlines():
        if iface in line:
            parts = line.split(":")
            if len(parts) == 2:
                nums = parts[1].split()
                if len(nums) >= 16:
                    return (int(nums[0]), int(nums[8]),
                            int(nums[1]), int(nums[9]),
                            int(nums[3]), int(nums[11]))
    return (0,0,0,0,0,0)

def get_temps():
    """Read hwmon temperatures in Celsius."""
    temps = {}
    for hwmon_dir in sorted(glob.glob("/sys/class/hwmon/hwmon*")):
        name = read_file(f"{hwmon_dir}/name").strip()
        for tfile in sorted(glob.glob(f"{hwmon_dir}/temp*_input")):
            label_file = tfile.replace("_input", "_label")
            label = read_file(label_file).strip() or os.path.basename(tfile)
            raw = read_int(tfile)
            key = f"temp_{name}_{label}".replace(" ","_")
            temps[key] = round(raw / 1000.0, 1)
    return temps

def get_main_iface():
    for line in read_file("/proc/net/route").splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[1] == "00000000":
            return parts[0]
    # Fallback — find interface with most traffic
    best, best_bytes = "lo", 0
    for line in read_file("/proc/net/dev").splitlines():
        if ":" in line:
            iface, _, rest = line.partition(":")
            iface = iface.strip()
            if iface == "lo":
                continue
            try:
                rx = int(rest.split()[0])
                if rx > best_bytes:
                    best_bytes = rx
                    best = iface
            except Exception:
                pass
    return best

# ── Build CSV header ──────────────────────────────────────────────────────────

NODE_FIELDS = (
    ["timestamp","node_cpu_user_pct","node_cpu_sys_pct","node_cpu_iowait_pct",
     "node_cpu_irq_pct","node_cpu_softirq_pct","node_cpu_idle_pct",
     "node_mem_total_MB","node_mem_used_MB","node_mem_free_MB",
     "node_mem_buffers_MB","node_mem_cached_MB","node_mem_avail_MB","node_swap_used_MB",
     "node_load1","node_load5","node_load15",
     "node_intr_per_s","node_ctxt_per_s",
     "node_softirq_NET_RX_per_s","node_softirq_NET_TX_per_s",
     "node_softirq_TIMER_per_s","node_softirq_SCHED_per_s",
     "node_softirq_TASKLET_per_s","node_softirq_RCU_per_s",
     "node_net_rx_bytes_s","node_net_tx_bytes_s",
     "node_net_rx_pkts_s","node_net_tx_pkts_s",
     "node_net_rx_drop_total","node_net_tx_drop_total"] +
    [f"node_cpu{i}_pct" for i in range(32)] +
    ["node_temp_package0_C","node_temp_package1_C","node_temp_core_max_C"]
)

PROC_FIELDS = (
    ["proc_pid","proc_name","proc_cpu_user_pct","proc_cpu_sys_pct",
     "proc_cpu_total_pct","proc_utime_s_delta","proc_stime_s_delta",
     "proc_rss_kB","proc_vsz_kB","proc_vmlock_kB","proc_vmhwm_kB",
     "proc_threads","proc_vol_ctxsw_s","proc_nonvol_ctxsw_s",
     "proc_schedrun_ns","proc_schedwait_ns","proc_schedrun_count",
     "proc_open_fds"]
)

Path(OUT_FILE).parent.mkdir(parents=True, exist_ok=True)
fout = open(OUT_FILE, "w", newline="")
writer = csv.DictWriter(fout, fieldnames=NODE_FIELDS + PROC_FIELDS)
writer.writeheader()
fout.flush()

print(f"[deep_sysmon] target={PROC_FILTER} duration={DURATION}s interval={INTERVAL}s → {OUT_FILE}")

# ── Find main network interface ───────────────────────────────────────────────
IFACE = get_main_iface()
print(f"[deep_sysmon] network interface: {IFACE}")

# ── Initial snapshots ─────────────────────────────────────────────────────────
prev_cpu_stat, prev_intr, prev_ctxt = parse_cpu_stat()
prev_softirq = parse_softirqs()
prev_net = parse_net_dev(IFACE)
prev_proc_stat = {}   # pid → (utime, stime, vol_ctx, nonvol_ctx, sched)

def snap_procs(procs):
    d = {}
    for pid, _ in procs:
        utime, stime = parse_proc_stat(pid)
        sched = parse_schedstat(pid)
        st = parse_status(pid)
        vol   = int(st.get("voluntary_ctxt_switches",   0))
        nonvol= int(st.get("nonvoluntary_ctxt_switches",0))
        d[pid] = (utime, stime, vol, nonvol, sched)
    return d

procs = get_procs(PROC_FILTER)
prev_proc_stat = snap_procs(procs)
t_start = time.time()
t_end   = t_start + DURATION
prev_t  = t_start

time.sleep(INTERVAL)

# ── Main loop ─────────────────────────────────────────────────────────────────
sample = 0
while time.time() < t_end:
    now_t = time.time()
    dt = now_t - prev_t
    prev_t = now_t
    sample += 1
    ts = time.strftime("%Y-%m-%dT%H:%M:%S")

    # ── Node CPU ──────────────────────────────────────────────────────────────
    curr_cpu_stat, curr_intr, curr_ctxt = parse_cpu_stat()
    total_pcts = cpu_pct(prev_cpu_stat.get("cpu", [0]*8), curr_cpu_stat.get("cpu", [0]*8))
    per_core_pcts = {}
    for i in range(32):
        key = f"cpu{i}"
        if key in curr_cpu_stat and key in prev_cpu_stat:
            p = cpu_pct(prev_cpu_stat[key], curr_cpu_stat[key])
            per_core_pcts[i] = round(100.0 - p["idle"], 2)
        else:
            per_core_pcts[i] = 0.0
    prev_cpu_stat = curr_cpu_stat

    intr_per_s  = round((curr_intr  - prev_intr)  / max(dt, 0.001))
    ctxt_per_s  = round((curr_ctxt  - prev_ctxt)  / max(dt, 0.001))
    prev_intr   = curr_intr
    prev_ctxt   = curr_ctxt

    # ── Softirq rates ─────────────────────────────────────────────────────────
    curr_softirq = parse_softirqs()
    sirq_rates = {}
    for k in ["NET_RX","NET_TX","TIMER","SCHED","TASKLET","RCU"]:
        curr_v = curr_softirq.get(k, 0)
        prev_v = prev_softirq.get(k, 0)
        sirq_rates[k] = round((curr_v - prev_v) / max(dt, 0.001))
    prev_softirq = curr_softirq

    # ── Memory ────────────────────────────────────────────────────────────────
    mem = parse_meminfo()
    mem_used = round(mem.get("MemTotal",0) - mem.get("MemAvailable",0), 1)
    swap_used = round(mem.get("SwapTotal",0) - mem.get("SwapFree",0), 1)

    # ── Load ──────────────────────────────────────────────────────────────────
    try:
        load1, load5, load15 = os.getloadavg()
    except Exception:
        load1 = load5 = load15 = 0.0

    # ── Network ───────────────────────────────────────────────────────────────
    curr_net = parse_net_dev(IFACE)
    net_rates = {
        "rx_bytes_s": round((curr_net[0]-prev_net[0])/max(dt,0.001)),
        "tx_bytes_s": round((curr_net[1]-prev_net[1])/max(dt,0.001)),
        "rx_pkts_s":  round((curr_net[2]-prev_net[2])/max(dt,0.001)),
        "tx_pkts_s":  round((curr_net[3]-prev_net[3])/max(dt,0.001)),
        "rx_drop":    curr_net[4],
        "tx_drop":    curr_net[5],
    }
    prev_net = curr_net

    # ── Temperatures ─────────────────────────────────────────────────────────
    temps = get_temps()
    pkg0 = "NA"; pkg1 = "NA"; core_max = "NA"
    core_vals = []
    for k, v in temps.items():
        kl = k.lower()
        if "package_id_0" in kl or "package0" in kl:
            pkg0 = v
        elif "package_id_1" in kl or "package1" in kl:
            pkg1 = v
        elif "core" in kl:
            core_vals.append(v)
    if core_vals:
        core_max = max(core_vals)

    # ── Build node row ────────────────────────────────────────────────────────
    node_row = {
        "timestamp": ts,
        "node_cpu_user_pct":    total_pcts["user"],
        "node_cpu_sys_pct":     total_pcts["sys"],
        "node_cpu_iowait_pct":  total_pcts["iowait"],
        "node_cpu_irq_pct":     total_pcts["irq"],
        "node_cpu_softirq_pct": total_pcts["softirq"],
        "node_cpu_idle_pct":    total_pcts["idle"],
        "node_mem_total_MB":    mem.get("MemTotal",0),
        "node_mem_used_MB":     mem_used,
        "node_mem_free_MB":     mem.get("MemFree",0),
        "node_mem_buffers_MB":  mem.get("Buffers",0),
        "node_mem_cached_MB":   mem.get("Cached",0),
        "node_mem_avail_MB":    mem.get("MemAvailable",0),
        "node_swap_used_MB":    swap_used,
        "node_load1": round(load1,2), "node_load5": round(load5,2), "node_load15": round(load15,2),
        "node_intr_per_s":  intr_per_s,
        "node_ctxt_per_s":  ctxt_per_s,
        "node_softirq_NET_RX_per_s":  sirq_rates.get("NET_RX",0),
        "node_softirq_NET_TX_per_s":  sirq_rates.get("NET_TX",0),
        "node_softirq_TIMER_per_s":   sirq_rates.get("TIMER",0),
        "node_softirq_SCHED_per_s":   sirq_rates.get("SCHED",0),
        "node_softirq_TASKLET_per_s": sirq_rates.get("TASKLET",0),
        "node_softirq_RCU_per_s":     sirq_rates.get("RCU",0),
        "node_net_rx_bytes_s":  net_rates["rx_bytes_s"],
        "node_net_tx_bytes_s":  net_rates["tx_bytes_s"],
        "node_net_rx_pkts_s":   net_rates["rx_pkts_s"],
        "node_net_tx_pkts_s":   net_rates["tx_pkts_s"],
        "node_net_rx_drop_total": net_rates["rx_drop"],
        "node_net_tx_drop_total": net_rates["tx_drop"],
        "node_temp_package0_C": pkg0,
        "node_temp_package1_C": pkg1,
        "node_temp_core_max_C": core_max,
    }
    for i in range(32):
        node_row[f"node_cpu{i}_pct"] = per_core_pcts.get(i, 0.0)

    # ── Per-process rows ─────────────────────────────────────────────────────
    procs = get_procs(PROC_FILTER)
    curr_proc_stat = snap_procs(procs)

    proc_rows = []
    for pid, cmd in procs:
        prev_p = prev_proc_stat.get(pid)
        curr_p = curr_proc_stat.get(pid)
        if not prev_p or not curr_p:
            continue
        p_ut, p_st, p_vol, p_nvol, p_sched_prev = prev_p
        c_ut, c_st, c_vol, c_nvol, c_sched_curr = curr_p

        utime_delta = (c_ut - p_ut) / HZ  # seconds of CPU (user)
        stime_delta = (c_st - p_st) / HZ  # seconds of CPU (kernel)
        cpu_user_pct = round(100.0 * utime_delta / max(dt, 0.001), 2)
        cpu_sys_pct  = round(100.0 * stime_delta / max(dt, 0.001), 2)

        vol_rate   = round((c_vol  - p_vol)  / max(dt, 0.001), 1)
        nvol_rate  = round((c_nvol - p_nvol) / max(dt, 0.001), 1)

        st = parse_status(pid)
        proc_rows.append({
            "proc_pid":           pid,
            "proc_name":          cmd.split("/")[-1][:40],
            "proc_cpu_user_pct":  cpu_user_pct,
            "proc_cpu_sys_pct":   cpu_sys_pct,
            "proc_cpu_total_pct": round(cpu_user_pct + cpu_sys_pct, 2),
            "proc_utime_s_delta": round(utime_delta, 4),
            "proc_stime_s_delta": round(stime_delta, 4),
            "proc_rss_kB":   int(st.get("VmRSS",  "0 kB").split()[0]),
            "proc_vsz_kB":   int(st.get("VmSize", "0 kB").split()[0]),
            "proc_vmlock_kB":int(st.get("VmLck",  "0 kB").split()[0]),
            "proc_vmhwm_kB": int(st.get("VmHWM",  "0 kB").split()[0]),
            "proc_threads":  int(st.get("Threads", 0)),
            "proc_vol_ctxsw_s":    vol_rate,
            "proc_nonvol_ctxsw_s": nvol_rate,
            "proc_schedrun_ns":    c_sched_curr[0],
            "proc_schedwait_ns":   c_sched_curr[1],
            "proc_schedrun_count": c_sched_curr[2],
            "proc_open_fds":       count_fds(pid),
        })
    prev_proc_stat = curr_proc_stat

    # ── Write one row per process (node cols repeated) ────────────────────────
    if proc_rows:
        for pr in proc_rows:
            row = {**node_row}
            row.update({k: "NA" for k in PROC_FIELDS})
            row.update(pr)
            writer.writerow(row)
    else:
        row = {**node_row, **{k: "NA" for k in PROC_FIELDS}}
        writer.writerow(row)

    fout.flush()
    elapsed = now_t - t_start
    remaining = t_end - time.time()
    if sample % 6 == 0:
        print(f"  [t={elapsed:.0f}s] sample={sample} procs={len(proc_rows)} "
              f"cpu_user={total_pcts['user']}% mem_used={mem_used:.0f}MB "
              f"core_max={core_max}C temp0={pkg0}C")

    if remaining > INTERVAL:
        time.sleep(INTERVAL)
    elif remaining > 0:
        time.sleep(remaining)
    else:
        break

fout.close()
print(f"\n[deep_sysmon] Done → {OUT_FILE}  ({sample} samples × {len(proc_rows or [1])} procs)")
