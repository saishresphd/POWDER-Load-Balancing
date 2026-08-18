#!/usr/bin/env bash
# =============================================================================
# run_ue51_100_lb_experiment.sh  — v2 (production-ready)
# =============================================================================
# For UE N in START_UE..END_UE (default 51..100), sequential:
#
#  Phase 1 – Attach UE N to gnb1, collect full telemetry (RAPL, sysmon,
#             IRQ, IPC, CPU freq, iperf3 DL+UL ramp, ping, RAN log)
#  Phase 2 – Kill from gnb1, load-balance to gnb2, collect post-HO telemetry
#             at FULL throughput (50 Mbps target), record HO timing.
#
# Usage:
#   bash run_ue51_100_lb_experiment.sh [START_UE] [END_UE]
#   bash run_ue51_100_lb_experiment.sh 51 51    # dry run single UE
#   bash run_ue51_100_lb_experiment.sh 51 100   # full batch
#
# Confirmed port map (live configs 2026-08):
#   gnb1 UE51: tx_port=40510  rx_port=10.10.1.4:40511
#   gnb2 UE51: tx_port=50010  rx_port=10.10.1.5:50011 (patched→10.10.1.4)
#   uehost1→gnb1 UE51: tx_port=70511 rx_port=10.10.1.3:70510
#   uehost1→gnb2 UE51: tx_port=50011 rx_port=10.10.1.3:50010 (written by script)
# =============================================================================

set -uo pipefail

# ── Node aliases ─────────────────────────────────────────────────────────────
GNB1="saish@pc818.emulab.net"
GNB2="saish@pc802.emulab.net"
UEH1="saish@pc808.emulab.net"
CORE="saish@pc811.emulab.net"
SSH="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=20 -o BatchMode=yes"
SCP="scp -o StrictHostKeyChecking=no -o BatchMode=yes"

# ── Experiment parameters ─────────────────────────────────────────────────────
ATTACH_TIMEOUT=180          # seconds to wait for UE to get IP (gnb2 can take ~90s)
RAMP_STEPS="1 5 10 20 50"  # Mbps ramp steps for gnb1 phase
GNB2_BW="50"               # Mbps target for gnb2 (highest throughput)
IPERF_DURATION=15           # seconds per iperf3 step
IPERF_PORT=5251             # separate from UE50 port 5250
SYSMON_INTERVAL=5           # seconds between sysmon rows during ramp
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Local output ──────────────────────────────────────────────────────────────
LOCAL_RESULTS="/tmp/ue51_100_results"
mkdir -p "$LOCAL_RESULTS"
MASTER_CSV="$LOCAL_RESULTS/master_ue51_100.csv"

# ── Logging ───────────────────────────────────────────────────────────────────
LOG_FILE="$LOCAL_RESULTS/experiment.log"
log() {
    local msg="[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}
epoch_now() { python3 -c "import time; print(f'{time.time():.3f}')"; }

# =============================================================================
# IMSI / Config helper
# =============================================================================
imsi_for_ue() { printf "999700000000%03d" "$1"; }
imei_for_ue()  { printf "35349006%07d"    "$1"; }

# Read port directly from live config using python3 (avoids grep -P which is not on emulab)
get_port() {
    # get_port NODE CONFFILE TYPE   (type: tx | rx)
    local node="$1" conf="$2" what="$3"
    $SSH "$node" python3 << PYEOF 2>/dev/null
import re
try:
    txt = open('$conf').read()
    if '$what' == 'tx':
        m = re.search(r'tx_port=tcp://\*:(\d+)', txt)
    else:
        m = re.search(r'rx_port=tcp://[0-9.]+:(\d+)', txt)
    print(m.group(1) if m else '')
except:
    print('')
PYEOF
}

# =============================================================================
# Master CSV header (write once)
# =============================================================================
init_master_csv() {
    if [ ! -f "$MASTER_CSV" ]; then
        cat > "$MASTER_CSV" << 'CSV_HDR'
ue_id,gnb,phase,step_mbps,timestamp_utc,epoch_s,attach_ok,attach_latency_s,ho_kill_ms,ho_attach_ms,ho_total_ms,ue_ip,ping_loss_pct,ping_rtt_min_ms,ping_rtt_avg_ms,ping_rtt_max_ms,ping_jitter_ms,iperf_dl_mbps,iperf_ul_mbps,iperf_dl_retransmits,iperf_ul_retransmits,gnb_pkg0_watts,gnb_pkg1_watts,gnb_total_watts,gnb_nof_ues,gnb_load1,gnb_load5,gnb_cpu_max_pct,sysmon_cpu_user_pct,sysmon_cpu_sys_pct,sysmon_cpu_softirq_pct,sysmon_cpu_idle_pct,sysmon_ctx_switches_per_s,sysmon_intr_per_s,sysmon_softirq_net_rx_per_s,sysmon_softirq_net_tx_per_s,sysmon_softirq_timer_per_s,sysmon_softirq_sched_per_s,sysmon_softirq_rcu_per_s,sysmon_ipc,sysmon_cpu_freq_mhz_avg,sysmon_rapl_uj_delta,proc_cpu_pct,proc_rss_kB,proc_sched_run_ns,proc_sched_wait_ns,ran_pdsch_prb_mean,ran_pdsch_prb_max,ran_pdsch_tbs_mean,ran_pusch_snr_db_mean,ran_pusch_snr_db_min,ran_pusch_rb_mean,ran_pusch_tbs_mean,ran_pusch_proc_us_mean,ran_pusch_proc_us_max,ran_pucch_snr_db_mean,ran_phr_db_mean,ran_bsr_mean,notes
CSV_HDR
        log "Master CSV created: $MASTER_CSV"
    fi
}

# =============================================================================
# Deep sysmon snapshot
# Captures: CPU user/sys/softirq/idle, ctx-switch, intr/s, softirq per-vec,
#           IPC (perf), CPU freq, RAPL delta, process stats
# Duration: ~SYSMON_INTERVAL seconds
# =============================================================================
sysmon_deep() {
    local node="$1" proc_pattern="$2" duration="${3:-5}"
    $SSH "$node" python3 << PYEOF 2>/dev/null
import time, re, subprocess, glob, os

DT = $duration

def rfile(f, default=''):
    try: return open(f).read()
    except: return default

# ── CPU stat snapshot ─────────────────────────────────────────────────────
def cpu_snap():
    lines = open('/proc/stat').readlines()
    total_line = lines[0].split()[1:]
    vals = [int(x) for x in total_line[:7]]  # user nice sys idle iowait irq softirq
    per_core = {}
    for l in lines[1:]:
        m = re.match(r'(cpu\d+)\s+(.+)', l)
        if m:
            p = [int(x) for x in m.group(2).split()[:7]]
            per_core[m.group(1)] = p
    return vals, per_core

# ── Softirq snapshot ──────────────────────────────────────────────────────
def softirq_snap():
    d = {}
    for l in open('/proc/softirqs'):
        p = l.split()
        if len(p) < 2: continue
        key = p[0].rstrip(':')
        try: d[key] = sum(int(x) for x in p[1:])
        except: pass
    return d

# ── Context switches + interrupts ─────────────────────────────────────────
def ctxintr_snap():
    ctx = 0; intr = 0
    for l in open('/proc/stat'):
        p = l.split()
        if p[0] == 'ctxt': ctx = int(p[1])
        if p[0] == 'intr': intr = int(p[1])
    return ctx, intr

# ── CPU freq ─────────────────────────────────────────────────────────────
def cpu_freq_mhz():
    freqs = []
    for f in glob.glob('/sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq'):
        try: freqs.append(int(open(f).read().strip()) / 1000)
        except: pass
    return sum(freqs)/len(freqs) if freqs else 0

# ── RAPL energy (needs sudo read) ─────────────────────────────────────────
def rapl_uj(pkg=0):
    import subprocess
    try:
        r = subprocess.run(['sudo', 'cat', f'/sys/class/powercap/intel-rapl:{pkg}/energy_uj'],
                          capture_output=True, text=True)
        return int(r.stdout.strip())
    except: return 0

# ── IPC via /proc/schedstat ───────────────────────────────────────────────
def schedstat_total():
    # sum running_ns and waiting_ns across all CPUs
    run_ns = 0; wait_ns = 0
    for l in open('/proc/schedstat'):
        p = l.split()
        if len(p) == 3 and p[0].startswith('cpu'):
            try: run_ns += int(p[1]); wait_ns += int(p[2])
            except: pass
    return run_ns, wait_ns

# ── Process stats ─────────────────────────────────────────────────────────
def proc_stats(pattern):
    for proc_dir in glob.glob('/proc/[0-9]*/cmdline'):
        try:
            cmd = open(proc_dir, 'rb').read().replace(b'\x00', b' ').decode(errors='replace')
            if pattern not in cmd or 'grep' in cmd or 'python' in cmd:
                continue
            pid = proc_dir.split('/')[2]
            stat = open(f'/proc/{pid}/stat').read().split()
            sched = open(f'/proc/{pid}/schedstat').read().split()
            status = open(f'/proc/{pid}/status').read()
            rss = int(re.search(r'VmRSS:\s+(\d+)', status).group(1))
            utime = int(stat[13]); stime = int(stat[14])
            cpu_ticks = utime + stime
            sched_run_ns  = int(sched[0]) if len(sched) > 0 else 0
            sched_wait_ns = int(sched[1]) if len(sched) > 1 else 0
            return cpu_ticks, rss, sched_run_ns, sched_wait_ns
        except: pass
    return 0, 0, 0, 0

# === T0 snapshots ============================================================
a_cpu, a_cores = cpu_snap()
a_sirq = softirq_snap()
a_ctx, a_intr = ctxintr_snap()
a_rapl0 = rapl_uj(0)
a_sched_run, a_sched_wait = schedstat_total()
a_freq = cpu_freq_mhz()
t0 = time.time()

time.sleep(DT)

# === T1 snapshots ============================================================
b_cpu, b_cores = cpu_snap()
b_sirq = softirq_snap()
b_ctx, b_intr = ctxintr_snap()
b_rapl0 = rapl_uj(0)
b_sched_run, b_sched_wait = schedstat_total()
b_freq = cpu_freq_mhz()
t1 = time.time()
dt = t1 - t0

# === Compute deltas =========================================================
dc = [b_cpu[i] - a_cpu[i] for i in range(7)]
total_ticks = sum(dc) or 1
user_p   = dc[0] * 100 / total_ticks
sys_p    = dc[2] * 100 / total_ticks
sirq_p   = dc[6] * 100 / total_ticks
idle_p   = dc[3] * 100 / total_ticks

# Per-core max busy
maxb = 0
for k in b_cores:
    if k in a_cores:
        d = [b_cores[k][i] - a_cores[k][i] for i in range(7)]
        tot = sum(d) or 1
        busy = 100 - d[3]*100//tot
        maxb = max(maxb, busy)

# Softirq per-vector per-second
def ds(key): return (b_sirq.get(key,0) - a_sirq.get(key,0)) / dt
net_rx_s  = ds('NET_RX')
net_tx_s  = ds('NET_TX')
timer_s   = ds('TIMER')
sched_s   = ds('SCHED')
rcu_s     = ds('RCU')

ctx_s  = (b_ctx  - a_ctx)  / dt
intr_s = (b_intr - a_intr) / dt

# IPC proxy: schedstat run time rate
sched_run_delta  = b_sched_run  - a_sched_run
sched_wait_delta = b_sched_wait - a_sched_wait
total_sched = sched_run_delta + sched_wait_delta
ipc = round(sched_run_delta / total_sched, 4) if total_sched > 1000 else round(user_p / 100, 4)

rapl_uj_delta = b_rapl0 - a_rapl0
freq_avg = (a_freq + b_freq) / 2

# Process
proc_ticks, proc_rss, proc_sched_run, proc_sched_wait = proc_stats('$proc_pattern')
# approx % from tick delta / (Hz * dt)
HZ = 100
proc_cpu_pct = proc_ticks / (HZ * dt) * 100

# Load avg
loadavg = open('/proc/loadavg').read().split()

print(','.join(map(str, [
    round(user_p,2),
    round(sys_p,2),
    round(sirq_p,2),
    round(idle_p,2),
    round(ctx_s,0),
    round(intr_s,0),
    round(net_rx_s,0),
    round(net_tx_s,0),
    round(timer_s,0),
    round(sched_s,0),
    round(rcu_s,0),
    round(ipc,4),
    round(freq_avg,1),
    rapl_uj_delta,
    round(proc_cpu_pct,2),
    proc_rss,
    proc_sched_run,
    proc_sched_wait,
    loadavg[0],
    loadavg[1],
    maxb
])))
PYEOF
}

# =============================================================================
# RAPL 2-second power measurement
# =============================================================================
rapl_watts() {
    local node="$1"
    $SSH "$node" python3 << 'RAPL' 2>/dev/null
import time
def read_uj(pkg):
    try: return int(open(f'/sys/class/powercap/intel-rapl:{pkg}/energy_uj').read())
    except: return 0
a0, a1 = read_uj(0), read_uj(1)
time.sleep(2)
b0, b1 = read_uj(0), read_uj(1)
p0 = (b0-a0)/2e6; p1 = (b1-a1)/2e6
print(f"{p0:.4f},{p1:.4f},{p0+p1:.4f}")
RAPL
}

# =============================================================================
# iperf3 single-step test  (returns: dl_mbps,ul_mbps,dl_rtr,ul_rtr)
# =============================================================================
iperf_step() {
    local netns="$1" bw_mbps="$2" outdir="$3" step="$4"
    local bw="${bw_mbps}M"
    mkdir -p "$outdir"

    # DL (reverse = server→UE)
    local dl_json
    dl_json=$($SSH "$UEH1" "sudo ip netns exec $netns iperf3 -c 10.45.0.1 -p ${IPERF_PORT} -b $bw -t ${IPERF_DURATION} -R -J 2>/dev/null" 2>/dev/null || echo '{}')
    echo "$dl_json" > "$outdir/dl_${step}.json"
    sleep 2

    # UL (UE→server)
    local ul_json
    ul_json=$($SSH "$UEH1" "sudo ip netns exec $netns iperf3 -c 10.45.0.1 -p ${IPERF_PORT} -b $bw -t ${IPERF_DURATION} -J 2>/dev/null" 2>/dev/null || echo '{}')
    echo "$ul_json" > "$outdir/ul_${step}.json"

    python3 << PYEOF 2>/dev/null
import json
def parse(path, key):
    try:
        d = json.load(open(path))
        s = d.get('end',{}).get(key,{})
        return round(s.get('bits_per_second',0)/1e6,4), s.get('retransmits',0)
    except: return 0.0, 0
dl, dl_r = parse('$outdir/dl_${step}.json', 'sum_received')
ul, ul_r = parse('$outdir/ul_${step}.json', 'sum_sent')
print(f"{dl},{ul},{dl_r},{ul_r}")
PYEOF
}

# =============================================================================
# Ping  (returns: loss_pct,min,avg,max,jitter)
# =============================================================================
do_ping() {
    local netns="$1" outfile="$2"
    local raw
    raw=$($SSH "$UEH1" "sudo ip netns exec $netns ping -c 30 -i 0.3 10.45.0.1 2>/dev/null" 2>/dev/null || echo "100% packet loss")
    echo "$raw" > "$outfile"
    python3 << PYEOF 2>/dev/null
import re
txt = open('$outfile').read()
rtt = re.search(r'min/avg/max/mdev = ([\d.]+)/([\d.]+)/([\d.]+)/([\d.]+)', txt)
loss = re.search(r'([\d.]+)% packet loss', txt)
pl = loss.group(1) if loss else '100'
if rtt:
    print(f"{pl},{rtt.group(1)},{rtt.group(2)},{rtt.group(3)},{rtt.group(4)}")
else:
    print(f"{pl},,,," )
PYEOF
}

# =============================================================================
# Wait for UE attachment (tun interface up with IP)
# =============================================================================
wait_attach() {
    local ue_id="$1"
    local deadline=$(( $(date +%s) + ATTACH_TIMEOUT ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        local ip
        ip=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes "$UEH1" python3 << WAEOF 2>/dev/null
import subprocess, re
try:
    r = subprocess.run(['sudo', 'ip', 'netns', 'exec', 'ue${ue_id}', 'ip', 'addr', 'show', 'tun_srsue${ue_id}'],
                       capture_output=True, text=True)
    m = re.search(r'inet (\\d+\\.\\d+\\.\\d+\\.\\d+)/', r.stdout)
    print(m.group(1) if m else '')
except:
    print('')
WAEOF
)
        if [ -n "$ip" ] && [ "$ip" != "" ]; then
            echo "$ip"
            return 0
        fi
        sleep 3
    done
    return 1
}

# =============================================================================
# RAN log quick snapshot (last 5000 lines)
# Returns: pdsch_prb_mean,pdsch_prb_max,pdsch_tbs_mean,
#          pusch_snr_mean,pusch_snr_min,pusch_rb_mean,pusch_tbs_mean,
#          pusch_proc_mean,pusch_proc_max,pucch_snr_mean,phr_mean,bsr_mean
# =============================================================================
ran_snapshot() {
    local node="$1" logfile="$2"
    $SSH "$node" "bash -c 'tail -n 5000 $logfile 2>/dev/null' | python3 -c \"
import sys, re, statistics as st
pd_prb=[]; pd_tbs=[]; pu_snr=[]; pu_rb=[]; pu_tbs=[]; pu_proc=[]; pucch_snr=[]; phr=[]; bsr=[]
for l in sys.stdin:
    m=re.search(r'PDSCH.*nof_prb=(\d+).*tbs=(\d+)', l)
    if m: pd_prb.append(int(m.group(1))); pd_tbs.append(int(m.group(2)))
    m=re.search(r'PUSCH.*rb=\(\d+,(\d+)\).*snr=([\d.]+).*tbs=(\d+).*t=(\d+) us', l)
    if m: pu_rb.append(int(m.group(1))); pu_snr.append(float(m.group(2))); pu_tbs.append(int(m.group(3))); pu_proc.append(int(m.group(4)))
    m=re.search(r'PUCCH.*snr=([\d.]+)', l)
    if m: pucch_snr.append(float(m.group(1)))
    m=re.search(r'PHR.*phr=(\d+)', l)
    if m: phr.append(int(m.group(1)))
    m=re.search(r'BSR.*lc0=(\d+)', l)
    if m: bsr.append(int(m.group(1)))
f=lambda v,fn: round(fn(v),2) if v else ''
mean=lambda v: f(v, lambda x: sum(x)/len(x))
print(','.join(map(str,[
    mean(pd_prb), f(pd_prb,max), mean(pd_tbs),
    mean(pu_snr), f(pu_snr,min), mean(pu_rb), mean(pu_tbs),
    mean(pu_proc), f(pu_proc,max), mean(pucch_snr), mean(phr), mean(bsr)
])))
\"" 2>/dev/null || echo ",,,,,,,,,,,"
}

# =============================================================================
# Write one row to master CSV
# =============================================================================
write_row() {
    local ue_id="$1" gnb="$2" phase="$3" step_mbps="$4"
    local attach_ok="$5" attach_lat="$6" ho_kill_ms="$7" ho_attach_ms="$8" ho_total_ms="$9" ue_ip="${10}"
    local ping_csv="${11}"        # loss,min,avg,max,jitter
    local iperf_csv="${12}"       # dl,ul,dl_rtr,ul_rtr
    local rapl_csv="${13}"        # pkg0,pkg1,total
    local nof_ues="${14}" load1="${15}" load5="${16}" cpu_max="${17}"
    local sysmon_csv="${18}"      # user,sys,sirq,idle,ctx_s,intr_s,net_rx,net_tx,timer,sched,rcu,ipc,freq,rapl_uj,proc_cpu,proc_rss,sched_run,sched_wait,load1,load5,maxb
    local ran_csv="${19}"         # pdsch_prb_mean,pdsch_prb_max,pdsch_tbs_mean,pusch_snr_mean,pusch_snr_min,pusch_rb_mean,pusch_tbs_mean,pusch_proc_mean,pusch_proc_max,pucch_snr_mean,phr_mean,bsr_mean
    local notes="${20}"

    local ts ep
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    ep=$(epoch_now)

    # Parse sysmon (21 fields: user,sys,sirq,idle,ctx_s,intr_s,net_rx,net_tx,timer,sched,rcu,ipc,freq,rapl_uj,proc_cpu,proc_rss,sched_run,sched_wait,load1,load5,maxb)
    IFS=',' read -r sm_user sm_sys sm_sirq sm_idle sm_ctx sm_intr sm_net_rx sm_net_tx sm_timer sm_sched sm_rcu sm_ipc sm_freq sm_rapl sm_pcpu sm_prss sm_srun sm_swait sm_l1 sm_l5 sm_maxb <<< "${sysmon_csv:-0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0}"

    IFS=',' read -r pkg0 pkg1 total   <<< "${rapl_csv:-0,0,0}"
    IFS=',' read -r dl ul dl_r ul_r   <<< "${iperf_csv:-0,0,0,0}"
    IFS=',' read -r p_loss p_min p_avg p_max p_jit <<< "${ping_csv:-100,,,,}"

    # ran (12 fields)
    IFS=',' read -r ran_pdprb_m ran_pdprb_x ran_pdtbs ran_pusnr_m ran_pusnr_n ran_purb ran_putbs ran_puproc_m ran_puproc_x ran_pucch ran_phr ran_bsr <<< "${ran_csv:-,,,,,,,,,,, }"

    echo "${ue_id},${gnb},${phase},${step_mbps},${ts},${ep},${attach_ok},${attach_lat},${ho_kill_ms},${ho_attach_ms},${ho_total_ms},${ue_ip},${p_loss},${p_min},${p_avg},${p_max},${p_jit},${dl},${ul},${dl_r},${ul_r},${pkg0},${pkg1},${total},${nof_ues},${load1},${load5},${cpu_max},${sm_user},${sm_sys},${sm_sirq},${sm_idle},${sm_ctx},${sm_intr},${sm_net_rx},${sm_net_tx},${sm_timer},${sm_sched},${sm_rcu},${sm_ipc},${sm_freq},${sm_rapl},${sm_pcpu},${sm_prss},${sm_srun},${sm_swait},${ran_pdprb_m},${ran_pdprb_x},${ran_pdtbs},${ran_pusnr_m},${ran_pusnr_n},${ran_purb},${ran_putbs},${ran_puproc_m},${ran_puproc_x},${ran_pucch},${ran_phr},${ran_bsr},${notes}" >> "$MASTER_CSV"
}

# =============================================================================
# Deploy parse_ran_log.py to both gNBs
# =============================================================================
deploy_parser() {
    local parser_src="$SCRIPT_DIR/parse_ran_log.py"
    if [ ! -f "$parser_src" ]; then
        log "  WARN: parse_ran_log.py not found at $parser_src — skipping deploy"
        return
    fi
    $SCP "$parser_src" "${GNB1}:/tmp/parse_ran_log.py" 2>/dev/null && log "  Parser deployed → gnb1" || log "  WARN: parser deploy failed gnb1"
    $SCP "$parser_src" "${GNB2}:/tmp/parse_ran_log.py" 2>/dev/null && log "  Parser deployed → gnb2" || log "  WARN: parser deploy failed gnb2"
}

# =============================================================================
# Collect full RAN log CSV (parse_ran_log.py output)
# =============================================================================
collect_ran_csv() {
    local node="$1" logfile="$2" outfile="$3"
    $SSH "$node" "[ -f $logfile ] && python3 /tmp/parse_ran_log.py $logfile /tmp/_ran_tmp.csv 2>/dev/null && cat /tmp/_ran_tmp.csv" > "$outfile" 2>/dev/null || true
    local rows
    rows=$(wc -l < "$outfile" 2>/dev/null || echo 0)
    log "  RAN CSV: $outfile ($rows rows)"
}

# =============================================================================
# Ensure iperf3 server on core port 5251
# =============================================================================
ensure_iperf_server() {
    $SSH "$CORE" "pgrep -f 'iperf3.*-p ${IPERF_PORT}' >/dev/null 2>&1 && echo running || \
        (nohup bash -c 'while true; do iperf3 -s -B 10.45.0.1 -p ${IPERF_PORT}; sleep 1; done' \
        >/tmp/iperf3_${IPERF_PORT}.log 2>&1 & echo started)" 2>/dev/null || true
}

# =============================================================================
# Gnb1 telemetry collection block (RAPL + sysmon + NOF_UES)
# =============================================================================
collect_gnb_sys() {
    local node="$1" proc_pattern="$2"
    local rapl nof_ues load1 load5 cpu_max sysmon
    rapl=$($SSH "$node" python3 << 'RAPL' 2>/dev/null
import time, subprocess
def r(p):
    try:
        res = subprocess.run(['sudo','cat',f'/sys/class/powercap/intel-rapl:{p}/energy_uj'],
                             capture_output=True, text=True)
        return int(res.stdout.strip())
    except: return 0
a0,a1=r(0),r(1)
time.sleep(2)
b0,b1=r(0),r(1)
p0=(b0-a0)/2e6; p1=(b1-a1)/2e6
print(f"{p0:.4f},{p1:.4f},{p0+p1:.4f}")
RAPL
)
    nof_ues=$($SSH "$node" "ps aux | grep srsenb | grep -v grep | wc -l" 2>/dev/null || echo 0)
    local loadavg
    loadavg=$($SSH "$node" "cat /proc/loadavg" 2>/dev/null || echo "0 0 0 0/0 0")
    load1=$(echo "$loadavg" | awk '{print $1}')
    load5=$(echo "$loadavg" | awk '{print $2}')
    cpu_max=$($SSH "$node" python3 << 'CPUMAX' 2>/dev/null
import re
m=0
for l in open('/proc/stat'):
    if not re.match(r'cpu\d',l): continue
    p=[int(x) for x in l.split()[1:8]]
    t=sum(p) or 1; m=max(m,100-p[3]*100//t)
print(m)
CPUMAX
)
    sysmon=$(sysmon_deep "$node" "$proc_pattern" "$SYSMON_INTERVAL")

    echo "${rapl:-0,0,0}|${nof_ues}|${load1}|${load5}|${cpu_max}|${sysmon:-0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0}"
}

# =============================================================================
# MAIN EXPERIMENT LOOP
# =============================================================================

START_UE=${1:-51}
END_UE=${2:-100}

init_master_csv
deploy_parser
ensure_iperf_server

log "═══════════════════════════════════════════════════════════"
log "UE LB EXPERIMENT  UE${START_UE}→${END_UE}  $(date -u)"
log "Results dir : $LOCAL_RESULTS"
log "Master CSV  : $MASTER_CSV"
log "iperf3 port : $IPERF_PORT   ramp: $RAMP_STEPS Mbps"
log "═══════════════════════════════════════════════════════════"

for UE_ID in $(seq "$START_UE" "$END_UE"); do

    log "──────────────────────────────────────────────────────"
    log "▶ UE${UE_ID}  [$(date -u '+%H:%M:%S UTC')]"
    log "──────────────────────────────────────────────────────"

    DIR="$LOCAL_RESULTS/ue${UE_ID}"
    mkdir -p "$DIR/gnb1/iperf" "$DIR/gnb1/sysmon" "$DIR/gnb1/ran" \
             "$DIR/gnb2/iperf" "$DIR/gnb2/sysmon" "$DIR/gnb2/ran"

    NETNS="ue${UE_ID}"
    IMSI=$(imsi_for_ue "$UE_ID")
    IMEI=$(imei_for_ue "$UE_ID")

    # ── Read ports from live configs ─────────────────────────────────────────
    GNB1_TX=$(get_port "$GNB1" "/etc/srsenb/enb_ue${UE_ID}.conf" tx)
    GNB1_RX=$(get_port "$GNB1" "/etc/srsenb/enb_ue${UE_ID}.conf" rx)
    GNB2_TX=$(get_port "$GNB2" "/etc/srsenb/enb_ue${UE_ID}.conf" tx)
    GNB2_RX=$(get_port "$GNB2" "/etc/srsenb/enb_ue${UE_ID}.conf" rx)
    UE_TX=$(get_port   "$UEH1" "/etc/srsue/ue${UE_ID}.conf"       tx)
    UE_RX=$(get_port   "$UEH1" "/etc/srsue/ue${UE_ID}.conf"       rx)

    log "  Ports  gnb1: TX=${GNB1_TX} RX=${GNB1_RX} | gnb2: TX=${GNB2_TX} RX=${GNB2_RX} | ue→gnb1: TX=${UE_TX} RX=${UE_RX}"

    if [ -z "$GNB1_TX" ] || [ -z "$GNB2_TX" ]; then
        log "  ERROR: Could not read ports for UE${UE_ID} — skipping"
        continue
    fi

    # ── Pre-flight: kill any stale UE51 processes from prior runs ────────────
    log "  Pre-flight cleanup: killing any stale UE${UE_ID} processes..."
    $SSH "$UEH1" "bash -c 'PIDS=\$(ps aux | grep \"srsue.*ue${UE_ID}\" | grep -v grep | awk \"{print \\\$2}\"); [ -n \"\$PIDS\" ] && sudo kill -9 \$PIDS 2>/dev/null; true'" 2>/dev/null || true
    $SSH "$GNB1" "bash -c 'PIDS=\$(ps aux | grep \"srsenb.*enb_ue${UE_ID}\" | grep -v grep | awk \"{print \\\$2}\"); [ -n \"\$PIDS\" ] && sudo kill -9 \$PIDS 2>/dev/null; true'" 2>/dev/null || true
    $SSH "$GNB2" "bash -c 'PIDS=\$(ps aux | grep \"srsenb.*enb_ue${UE_ID}\" | grep -v grep | awk \"{print \\\$2}\"); [ -n \"\$PIDS\" ] && sudo kill -9 \$PIDS 2>/dev/null; true'" 2>/dev/null || true
    sleep 3

    # ═══════════════════════════════════════════════════════════════════════
    # PHASE 1 — Attach to gnb1, throughput ramp, collect full telemetry
    # ═══════════════════════════════════════════════════════════════════════
    log "  [Phase 1] Starting srsenb slot on gnb1..."
    $SSH "$GNB1" "bash -c 'sudo mkdir -p /tmp/gnb1_logs; sudo rm -f /tmp/gnb1_logs/ue${UE_ID}_stdout.log; sudo touch /tmp/gnb1_logs/ue${UE_ID}_stdout.log; sudo chmod 666 /tmp/gnb1_logs/ue${UE_ID}_stdout.log; sudo bash -c \"srsenb /etc/srsenb/enb_ue${UE_ID}.conf </dev/null >>/tmp/gnb1_logs/ue${UE_ID}_stdout.log 2>&1 &\"'" 2>/dev/null
    sleep 3

    log "  [Phase 1] Starting srsue UE${UE_ID} → gnb1..."
    T0_ATTACH=$(epoch_now)
    $SSH "$UEH1" "bash -c 'sudo rm -f /tmp/ue${UE_ID}_stdout.log; sudo touch /tmp/ue${UE_ID}_stdout.log; sudo chmod 666 /tmp/ue${UE_ID}_stdout.log; sudo bash -c \"srsue /etc/srsue/ue${UE_ID}.conf </dev/null >>/tmp/ue${UE_ID}_stdout.log 2>&1 &\"'" 2>/dev/null

    UE_IP_GNB1=""; ATTACH_OK_GNB1=0; ATTACH_LAT_GNB1=""
    if UE_IP_GNB1=$(wait_attach "$UE_ID"); then
        T_ATTACHED=$(epoch_now)
        ATTACH_LAT_GNB1=$(python3 -c "print(round($T_ATTACHED-$T0_ATTACH,2))")
        ATTACH_OK_GNB1=1
        log "  ✓ UE${UE_ID} attached gnb1  IP=${UE_IP_GNB1}  lat=${ATTACH_LAT_GNB1}s"
    else
        log "  ✗ UE${UE_ID} did NOT attach gnb1 (timeout=${ATTACH_TIMEOUT}s)"
    fi

    # ── Throughput ramp on gnb1 ──────────────────────────────────────────────
    for BW in $RAMP_STEPS; do
        log "  [gnb1 ramp] ${BW} Mbps step..."

        # Collect gnb sys telemetry (runs in parallel with iperf)
        GNB1_SYS=$(collect_gnb_sys "$GNB1" "enb_ue${UE_ID}.conf")
        RAPL_GNB1=$(echo "$GNB1_SYS" | cut -d'|' -f1)
        NOF_UES_GNB1=$(echo "$GNB1_SYS" | cut -d'|' -f2)
        LOAD1_GNB1=$(echo "$GNB1_SYS"   | cut -d'|' -f3)
        LOAD5_GNB1=$(echo "$GNB1_SYS"   | cut -d'|' -f4)
        CPUMAX_GNB1=$(echo "$GNB1_SYS"  | cut -d'|' -f5)
        SYSMON_GNB1=$(echo "$GNB1_SYS"  | cut -d'|' -f6)

        # iperf step
        IPERF_GNB1="0,0,0,0"
        if [ "$ATTACH_OK_GNB1" = "1" ]; then
            IPERF_GNB1=$(iperf_step "$NETNS" "$BW" "$DIR/gnb1/iperf" "${BW}mbps" 2>/dev/null || echo "0,0,0,0")
        fi

        # Ping at this ramp step
        PING_GNB1="100,,,,"
        if [ "$ATTACH_OK_GNB1" = "1" ]; then
            PING_GNB1=$(do_ping "$NETNS" "$DIR/gnb1/ping_${BW}mbps.txt" 2>/dev/null || echo "100,,,,")
        fi

        # RAN snapshot
        RAN_GNB1=$(ran_snapshot "$GNB1" "/tmp/gnb1_logs/ue${UE_ID}.log" 2>/dev/null || echo ",,,,,,,,,,,")

        write_row "$UE_ID" "gnb1" "ramp" "$BW" \
            "$ATTACH_OK_GNB1" "$ATTACH_LAT_GNB1" "" "" "" "${UE_IP_GNB1:-}" \
            "$PING_GNB1" "$IPERF_GNB1" "$RAPL_GNB1" \
            "$NOF_UES_GNB1" "$LOAD1_GNB1" "$LOAD5_GNB1" "$CPUMAX_GNB1" \
            "$SYSMON_GNB1" "$RAN_GNB1" \
            "UE${UE_ID}_gnb1_${BW}mbps"

        log "  gnb1 ${BW}Mbps: dl=$(echo $IPERF_GNB1|cut -d, -f1) ul=$(echo $IPERF_GNB1|cut -d, -f2) RAPL=$(echo $RAPL_GNB1|cut -d, -f3)W load=${LOAD1_GNB1}"
    done

    # Save full gnb1 RAN log CSV
    collect_ran_csv "$GNB1" "/tmp/gnb1_logs/ue${UE_ID}.log" "$DIR/gnb1/ran/ran_metrics.csv"

    # ═══════════════════════════════════════════════════════════════════════
    # HANDOVER — Kill from gnb1, record timing
    # ═══════════════════════════════════════════════════════════════════════
    log "  [HO T0] Killing UE${UE_ID} on gnb1..."
    T_HO_T0=$(epoch_now)

    # Step 1: Kill only the srsue (not gnb1 srsenb) so MME gets proper detach signaling
    $SSH "$UEH1" "bash -c 'PIDS=\$(ps aux | grep \"srsue.*ue${UE_ID}\\.conf\" | grep -v grep | awk \"{print \\\$2}\"); [ -n \"\$PIDS\" ] && sudo kill -15 \$PIDS 2>/dev/null; sleep 3; PIDS=\$(ps aux | grep \"srsue.*ue${UE_ID}\" | grep -v grep | awk \"{print \\\$2}\"); [ -n \"\$PIDS\" ] && sudo kill -9 \$PIDS 2>/dev/null; true'" 2>/dev/null || true
    sleep 8
    # Step 2: Kill gnb1 srsenb AFTER UE has signalled detach
    $SSH "$GNB1" "bash -c 'PIDS=\$(ps aux | grep \"srsenb.*enb_ue${UE_ID}\" | grep -v grep | awk \"{print \\\$2}\"); [ -n \"\$PIDS\" ] && sudo kill -15 \$PIDS 2>/dev/null; sleep 3; PIDS=\$(ps aux | grep \"srsenb.*enb_ue${UE_ID}\" | grep -v grep | awk \"{print \\\$2}\"); [ -n \"\$PIDS\" ] && sudo kill -9 \$PIDS 2>/dev/null; true'" 2>/dev/null || true
    sleep 3

    T_HO_KILL=$(epoch_now)
    HO_KILL_MS=$(python3 -c "print(round(($T_HO_KILL-$T_HO_T0)*1000,1))")
    log "  [HO T1] Kill done in ${HO_KILL_MS}ms"

    # Collect gnb1 state snapshot immediately after kill
    GNB1_SYS_POST=$(collect_gnb_sys "$GNB1" "enb")
    RAPL_GNB1_POST=$(echo "$GNB1_SYS_POST" | cut -d'|' -f1)
    NOF_UES_GNB1_POST=$(echo "$GNB1_SYS_POST" | cut -d'|' -f2)
    LOAD1_GNB1_POST=$(echo "$GNB1_SYS_POST" | cut -d'|' -f3)
    LOAD5_GNB1_POST=$(echo "$GNB1_SYS_POST" | cut -d'|' -f4)
    CPUMAX_GNB1_POST=$(echo "$GNB1_SYS_POST" | cut -d'|' -f5)
    SYSMON_GNB1_POST=$(echo "$GNB1_SYS_POST" | cut -d'|' -f6)

    write_row "$UE_ID" "gnb1" "post_kill" "0" \
        "0" "" "$HO_KILL_MS" "" "" "" \
        "0,,,," "0,0,0,0" "$RAPL_GNB1_POST" \
        "$NOF_UES_GNB1_POST" "$LOAD1_GNB1_POST" "$LOAD5_GNB1_POST" "$CPUMAX_GNB1_POST" \
        "$SYSMON_GNB1_POST" ",,,,,,,,,,," \
        "UE${UE_ID}_gnb1_post_kill"
    log "  gnb1 post-kill: RAPL=$(echo $RAPL_GNB1_POST|cut -d, -f3)W  nof_ues=${NOF_UES_GNB1_POST}  load=${LOAD1_GNB1_POST}"

    # Give MME time to clear the UE context from gnb1 (needed for clean gnb2 attach)
    log "  Waiting 30s for MME UE context cleanup..."
    sleep 30

    # ═══════════════════════════════════════════════════════════════════════
    # PHASE 2 — Attach to gnb2 (load balance destination)
    # ═══════════════════════════════════════════════════════════════════════
    log "  [Phase 2] Preparing gnb2 for UE${UE_ID}..."

    # Patch gnb2 config: override rx_port from uehost2 (10.10.1.5) to uehost1 (10.10.1.4)
    $SSH "$GNB2" "sudo sed -i \
        's|rx_port=tcp://10\.10\.1\.5:${GNB2_RX}|rx_port=tcp://10.10.1.4:${GNB2_RX}|g' \
        /etc/srsenb/enb_ue${UE_ID}.conf" 2>/dev/null || true

    # Write ue{N}_gnb2.conf on uehost1 using python3 (avoids tcsh escaping issues)
    # UE→gnb2: tx_port = GNB2_RX (UE sends to gnb2's rx), rx_port = gnb2's tx
    $SSH "$UEH1" python3 << GNBCONF 2>/dev/null
content = """[rf]
freq_offset  = 0
tx_gain      = 80
rx_gain      = 40
nof_antennas = 1
device_name  = zmq
device_args  = fail_on_disconnect=true,tx_port=tcp://*:${GNB2_RX},rx_port=tcp://10.10.1.3:${GNB2_TX},id=ue${UE_ID}_gnb2,base_srate=11.52e6

[rat.eutra]
dl_earfcn    = 3350
nof_carriers = 1

[usim]
mode = soft
algo = milenage
opc  = 63bfa50ee6523365ff14c1f45f88737d
k    = 00112233445566778899aabbccddeeff
imsi = ${IMSI}
imei = ${IMEI}

[rrc]
release     = 8
ue_category = 4

[nas]
apn          = internet
apn_protocol = ipv4

[gw]
netns      = ue${UE_ID}
ip_devname = tun_srsue${UE_ID}
ip_netmask = 255.255.255.0

[log]
all_level    = info
filename     = /tmp/ue${UE_ID}_gnb2.log
file_max_size = -1
"""
import subprocess
subprocess.run(['sudo','tee','/etc/srsue/ue${UE_ID}_gnb2.conf'], input=content.encode(), capture_output=True)
print('written')
GNBCONF
    log "  ✓ ue${UE_ID}_gnb2.conf written"

    log "  [gnb2] Starting srsenb slot..."
    $SSH "$GNB2" "bash -c 'sudo mkdir -p /tmp/gnb2_logs; sudo rm -f /tmp/gnb2_logs/ue${UE_ID}_stdout.log; sudo touch /tmp/gnb2_logs/ue${UE_ID}_stdout.log; sudo chmod 666 /tmp/gnb2_logs/ue${UE_ID}_stdout.log; sudo bash -c \"srsenb /etc/srsenb/enb_ue${UE_ID}.conf </dev/null >>/tmp/gnb2_logs/ue${UE_ID}_stdout.log 2>&1 &\"'" 2>/dev/null
    sleep 5

    log "  [uehost1] Starting srsue UE${UE_ID} → gnb2..."
    T0_ATTACH_GNB2=$(epoch_now)
    $SSH "$UEH1" "bash -c 'sudo rm -f /tmp/ue${UE_ID}_gnb2_stdout.log; sudo touch /tmp/ue${UE_ID}_gnb2_stdout.log; sudo chmod 666 /tmp/ue${UE_ID}_gnb2_stdout.log; sudo bash -c \"srsue /etc/srsue/ue${UE_ID}_gnb2.conf </dev/null >>/tmp/ue${UE_ID}_gnb2_stdout.log 2>&1 &\"'" 2>/dev/null

    UE_IP_GNB2=""; ATTACH_OK_GNB2=0; ATTACH_LAT_GNB2=""; HO_ATTACH_MS=""; HO_TOTAL_MS=""
    # For gnb2, use dual detection: TUN IP OR gnb2 stdout log "Network attach successful"
    # gnb2 may release quickly on 1st attempt then succeed on retry
    GNB2_ATTACH_LOG="/tmp/ue${UE_ID}_gnb2_stdout.log"
    GNB2_DEADLINE=$(( $(date +%s) + ATTACH_TIMEOUT ))
    while [ "$(date +%s)" -lt "$GNB2_DEADLINE" ]; do
        UE_IP_GNB2=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes "$UEH1" python3 << WAEOF2 2>/dev/null
import subprocess, re
try:
    r = subprocess.run(['sudo', 'ip', 'netns', 'exec', 'ue${UE_ID}', 'ip', 'addr', 'show', 'tun_srsue${UE_ID}'],
                       capture_output=True, text=True)
    m = re.search(r'inet (\\d+\\.\\d+\\.\\d+\\.\\d+)/', r.stdout)
    # Also check stdout log for "Network attach successful"
    log_ok = False
    try:
        log_ok = 'Network attach successful' in open('/tmp/ue${UE_ID}_gnb2_stdout.log').read()
    except: pass
    ip = m.group(1) if m else ''
    if not ip and log_ok:
        ip = 'from_log'
    print(ip)
except:
    print('')
WAEOF2
)
        if [ -n "$UE_IP_GNB2" ] && [ "$UE_IP_GNB2" != "" ]; then
            if [ "$UE_IP_GNB2" = "from_log" ]; then
                # Get IP from the stdout log
                UE_IP_GNB2=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes "$UEH1" python3 << IPEOF 2>/dev/null
import re
try:
    txt = open('/tmp/ue${UE_ID}_gnb2_stdout.log').read()
    m = re.search(r'IP: (\d+\.\d+\.\d+\.\d+)', txt)
    print(m.group(1) if m else 'attached')
except: print('attached')
IPEOF
)
            fi
            T_ATTACHED_GNB2=$(epoch_now)
            ATTACH_LAT_GNB2=$(python3 -c "print(round($T_ATTACHED_GNB2-$T0_ATTACH_GNB2,2))")
            HO_ATTACH_MS=$(python3 -c "print(round(($T_ATTACHED_GNB2-$T_HO_KILL)*1000,1))")
            HO_TOTAL_MS=$(python3 -c "print(round(($T_ATTACHED_GNB2-$T_HO_T0)*1000,1))")
            ATTACH_OK_GNB2=1
            log "  ✓ UE${UE_ID} attached gnb2  IP=${UE_IP_GNB2}  HO_total=${HO_TOTAL_MS}ms  HO_attach=${HO_ATTACH_MS}ms"
            break
        fi
        sleep 5
    done
    [ "$ATTACH_OK_GNB2" != "1" ] && log "  ✗ UE${UE_ID} did NOT attach gnb2 (timeout=${ATTACH_TIMEOUT}s)"

    # ── Collect gnb2 telemetry at maximum throughput ─────────────────────────
    log "  [gnb2] Collecting telemetry at ${GNB2_BW}Mbps..."

    GNB2_SYS=$(collect_gnb_sys "$GNB2" "enb_ue${UE_ID}.conf")
    RAPL_GNB2=$(echo "$GNB2_SYS" | cut -d'|' -f1)
    NOF_UES_GNB2=$(echo "$GNB2_SYS" | cut -d'|' -f2)
    LOAD1_GNB2=$(echo "$GNB2_SYS"   | cut -d'|' -f3)
    LOAD5_GNB2=$(echo "$GNB2_SYS"   | cut -d'|' -f4)
    CPUMAX_GNB2=$(echo "$GNB2_SYS"  | cut -d'|' -f5)
    SYSMON_GNB2=$(echo "$GNB2_SYS"  | cut -d'|' -f6)

    IPERF_GNB2="0,0,0,0"
    PING_GNB2="100,,,,"
    if [ "$ATTACH_OK_GNB2" = "1" ]; then
        IPERF_GNB2=$(iperf_step "$NETNS" "$GNB2_BW" "$DIR/gnb2/iperf" "${GNB2_BW}mbps" 2>/dev/null || echo "0,0,0,0")
        PING_GNB2=$(do_ping "$NETNS" "$DIR/gnb2/ping.txt" 2>/dev/null || echo "100,,,,")
    fi

    RAN_GNB2=$(ran_snapshot "$GNB2" "/tmp/gnb2_logs/ue${UE_ID}.log" 2>/dev/null || echo ",,,,,,,,,,,")

    write_row "$UE_ID" "gnb2" "post_lb" "$GNB2_BW" \
        "$ATTACH_OK_GNB2" "$ATTACH_LAT_GNB2" "$HO_KILL_MS" "${HO_ATTACH_MS:-}" "${HO_TOTAL_MS:-}" "${UE_IP_GNB2:-}" \
        "$PING_GNB2" "$IPERF_GNB2" "$RAPL_GNB2" \
        "$NOF_UES_GNB2" "$LOAD1_GNB2" "$LOAD5_GNB2" "$CPUMAX_GNB2" \
        "$SYSMON_GNB2" "$RAN_GNB2" \
        "UE${UE_ID}_gnb2_postLB_${GNB2_BW}mbps"

    collect_ran_csv "$GNB2" "/tmp/gnb2_logs/ue${UE_ID}.log" "$DIR/gnb2/ran/ran_metrics.csv"

    log "  gnb2 post-LB: dl=$(echo $IPERF_GNB2|cut -d, -f1) ul=$(echo $IPERF_GNB2|cut -d, -f2) RAPL=$(echo $RAPL_GNB2|cut -d, -f3)W HO=${HO_TOTAL_MS}ms"
    log "  ✓ UE${UE_ID} complete — left running on gnb2"
    echo ""

done

log "═══════════════════════════════════════════════════════════"
log "DONE  UE${START_UE}–${END_UE}"
log "Master CSV rows: $(wc -l < "$MASTER_CSV")"
log "Results dir    : $LOCAL_RESULTS"
log "═══════════════════════════════════════════════════════════"
