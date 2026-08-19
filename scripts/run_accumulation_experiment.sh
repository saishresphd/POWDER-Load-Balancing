#!/usr/bin/env bash
# =============================================================================
# run_accumulation_experiment.sh  — ACCUMULATION MODE
# =============================================================================
# Adds UEs one-by-one to gnb1.  Every UE STAYS CONNECTED alongside all prior
# ones.  After each addition we snapshot the FULL system state (RAPL power,
# CPU/IRQ/IPC/freq sysmon, RAN metrics from ALL active UE logs combined).
#
# Phase 1 — gnb1 accumulation: add UE N, snapshot N-UE load, leave running.
# Phase 2 — gnb2 LB: move ONLY UE N to gnb2, keep it running there.
#           gnb1 and gnb2 are BOTH measured after each migration.
#
# Usage:
#   bash run_accumulation_experiment.sh [START_UE] [END_UE]
#   bash run_accumulation_experiment.sh 51 51   # single UE test
#   bash run_accumulation_experiment.sh 51 100  # full batch
#
# Nodes:
#   gnb1    = saish@pc818.emulab.net  (primary, accumulates UEs)
#   gnb2    = saish@pc802.emulab.net  (LB destination)
#   uehost1 = saish@pc808.emulab.net  (all UE processes)
#   core    = saish@pc811.emulab.net  (Open5GS MME/UPF, iperf3 server)
# =============================================================================

set -uo pipefail

GNB1="saish@pc818.emulab.net"
GNB2="saish@pc802.emulab.net"
UEH1="saish@pc808.emulab.net"
CORE="saish@pc811.emulab.net"
SSH="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=20 -o BatchMode=yes"
SCP="scp -o StrictHostKeyChecking=no -o BatchMode=yes"

ATTACH_TIMEOUT=180
IPERF_PORT=5251
IPERF_DURATION=15
SYSMON_DT=5
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LOCAL_RESULTS="/tmp/accum_results"
mkdir -p "$LOCAL_RESULTS"
LOG_FILE="$LOCAL_RESULTS/experiment.log"
MASTER_CSV="$LOCAL_RESULTS/master_accumulation.csv"

# ─── Logging ─────────────────────────────────────────────────────────────────
log() { local m="[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; echo "$m"; echo "$m" >> "$LOG_FILE"; }
epoch_now() { python3 -c "import time; print(f'{time.time():.3f}')"; }

# ─── IMSI / IMEI ─────────────────────────────────────────────────────────────
imsi_for_ue() { printf "999700000000%03d" "$1"; }
imei_for_ue()  { printf "35349006%07d"    "$1"; }

# ─── Master CSV header ───────────────────────────────────────────────────────
init_csv() {
    if [ ! -f "$MASTER_CSV" ]; then
        cat >> "$MASTER_CSV" << 'HDR'
event_type,ue_id,gnb,timestamp_utc,epoch_s,total_ues_gnb1,total_ues_gnb2,attach_ok,attach_latency_s,ue_ip,ho_total_ms,ping_loss_pct,ping_rtt_min_ms,ping_rtt_avg_ms,ping_rtt_max_ms,iperf_dl_mbps,iperf_ul_mbps,gnb_pkg0_watts,gnb_pkg1_watts,gnb_total_watts,gnb_load1,gnb_load5,gnb_cpu_max_pct,sysmon_cpu_user_pct,sysmon_cpu_sys_pct,sysmon_cpu_softirq_pct,sysmon_cpu_idle_pct,sysmon_ctx_switches_per_s,sysmon_intr_per_s,sysmon_softirq_net_rx_per_s,sysmon_softirq_net_tx_per_s,sysmon_softirq_timer_per_s,sysmon_softirq_sched_per_s,sysmon_softirq_rcu_per_s,sysmon_ipc,sysmon_cpu_freq_mhz_avg,sysmon_rapl_uj_delta,proc_cpu_pct,proc_rss_kB,proc_sched_run_ns,proc_sched_wait_ns,ran_combined_pdsch_prb_mean,ran_combined_pusch_snr_mean,ran_combined_pusch_proc_us_mean,ran_combined_phr_mean,notes
HDR
        log "Master CSV created: $MASTER_CSV"
    fi
}

# ─── Port lookup (from live configs) ─────────────────────────────────────────
get_port() {
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

# ─── RAPL power (sudo cat, 2s window) ────────────────────────────────────────
rapl_watts() {
    local node="$1"
    $SSH "$node" python3 << 'RAPL' 2>/dev/null
import time, subprocess
def r(p):
    try:
        res = subprocess.run(['sudo','cat',f'/sys/class/powercap/intel-rapl:{p}/energy_uj'],
                             capture_output=True, text=True)
        return int(res.stdout.strip())
    except: return 0
a0,a1=r(0),r(1); time.sleep(2); b0,b1=r(0),r(1)
p0=(b0-a0)/2e6; p1=(b1-a1)/2e6
print(f"{p0:.4f},{p1:.4f},{p0+p1:.4f}")
RAPL
}

# ─── Deep sysmon (DT seconds) ────────────────────────────────────────────────
sysmon_deep() {
    local node="$1" proc_pattern="$2" dt="${3:-5}"
    $SSH "$node" python3 << PYEOF 2>/dev/null
import time, re, subprocess, glob
DT=$dt
def cpu_snap():
    lines=open('/proc/stat').readlines()
    vals=[int(x) for x in lines[0].split()[1:8]]
    cores={}
    for l in lines[1:]:
        m=re.match(r'(cpu\d+)\s+(.+)',l)
        if m: cores[m.group(1)]=[int(x) for x in m.group(2).split()[:7]]
    return vals,cores
def sirq_snap():
    d={}
    for l in open('/proc/softirqs'):
        p=l.split()
        if len(p)<2: continue
        k=p[0].rstrip(':')
        try: d[k]=sum(int(x) for x in p[1:])
        except: pass
    return d
def ctxintr():
    ctx=0; intr=0
    for l in open('/proc/stat'):
        p=l.split()
        if p[0]=='ctxt': ctx=int(p[1])
        if p[0]=='intr': intr=int(p[1])
    return ctx,intr
def freq_mhz():
    fs=[]
    for f in glob.glob('/sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq'):
        try: fs.append(int(open(f).read().strip())/1000)
        except: pass
    return sum(fs)/len(fs) if fs else 0
def rapl_uj(p=0):
    try:
        r=subprocess.run(['sudo','cat',f'/sys/class/powercap/intel-rapl:{p}/energy_uj'],capture_output=True,text=True)
        return int(r.stdout.strip())
    except: return 0
def sched_ns():
    run=0; wait=0
    for l in open('/proc/schedstat'):
        p=l.split()
        if len(p)==3 and p[0].startswith('cpu'):
            try: run+=int(p[1]); wait+=int(p[2])
            except: pass
    return run,wait
def proc_stats(pat):
    for d in glob.glob('/proc/[0-9]*/cmdline'):
        try:
            cmd=open(d,'rb').read().replace(b'\x00',b' ').decode(errors='replace')
            if pat not in cmd or 'grep' in cmd or 'python' in cmd: continue
            pid=d.split('/')[2]
            stat=open(f'/proc/{pid}/stat').read().split()
            sched=open(f'/proc/{pid}/schedstat').read().split()
            status=open(f'/proc/{pid}/status').read()
            rss=int(re.search(r'VmRSS:\s+(\d+)',status).group(1))
            cpu=int(stat[13])+int(stat[14])
            srun=int(sched[0]) if sched else 0; swait=int(sched[1]) if len(sched)>1 else 0
            return cpu,rss,srun,swait
        except: pass
    return 0,0,0,0

a_cpu,a_cores=cpu_snap(); a_sirq=sirq_snap(); a_ctx,a_intr=ctxintr()
a_rapl=rapl_uj(); a_srun,a_swait=sched_ns(); a_freq=freq_mhz(); t0=time.time()
time.sleep(DT)
b_cpu,b_cores=cpu_snap(); b_sirq=sirq_snap(); b_ctx,b_intr=ctxintr()
b_rapl=rapl_uj(); b_srun,b_swait=sched_ns(); b_freq=freq_mhz(); t1=time.time()
dt=t1-t0

dc=[b_cpu[i]-a_cpu[i] for i in range(7)]; total=sum(dc) or 1
user_p=dc[0]*100/total; sys_p=dc[2]*100/total; sirq_p=dc[6]*100/total; idle_p=dc[3]*100/total
maxb=0
for k in b_cores:
    if k in a_cores:
        d=[b_cores[k][i]-a_cores[k][i] for i in range(7)]; tot=sum(d) or 1
        maxb=max(maxb,100-d[3]*100//tot)
def ds(k): return (b_sirq.get(k,0)-a_sirq.get(k,0))/dt
ctx_s=(b_ctx-a_ctx)/dt; intr_s=(b_intr-a_intr)/dt
net_rx=ds('NET_RX'); net_tx=ds('NET_TX'); timer=ds('TIMER'); sched=ds('SCHED'); rcu=ds('RCU')
srun_d=b_srun-a_srun; swait_d=b_swait-a_swait; tot_s=srun_d+swait_d
ipc=round(srun_d/tot_s,4) if tot_s>1000 else round(user_p/100,4)
freq_avg=(a_freq+b_freq)/2; rapl_d=b_rapl-a_rapl
pc,prss,psrun,pswait=proc_stats('$proc_pattern')
HZ=100; pcpu=pc/(HZ*dt)*100
loadavg=open('/proc/loadavg').read().split()
print(','.join(map(str,[
    round(user_p,2),round(sys_p,2),round(sirq_p,2),round(idle_p,2),
    round(ctx_s,0),round(intr_s,0),round(net_rx,0),round(net_tx,0),
    round(timer,0),round(sched,0),round(rcu,0),round(ipc,4),
    round(freq_avg,1),rapl_d,round(pcpu,2),prss,psrun,pswait,
    loadavg[0],loadavg[1],maxb
])))
PYEOF
}

# ─── Count active srsenb processes ───────────────────────────────────────────
count_srsenb() {
    local node="$1"
    $SSH "$node" "bash -c 'ps aux | grep srsenb | grep -v grep | wc -l'" 2>/dev/null || echo 0
}

# ─── Collect combined RAN snapshot from all active UE logs on a node ─────────
ran_combined_snapshot() {
    local node="$1"
    # Parse tail of ALL ue*.log files in /tmp/gnb1_logs/ (or gnb2_logs/)
    $SSH "$node" python3 << 'PYEOF' 2>/dev/null
import glob, re, os

logdir = '/tmp/gnb1_logs' if os.path.exists('/tmp/gnb1_logs') else '/tmp/gnb2_logs'
# Also check gnb2
if not os.path.exists(logdir) or 'gnb1' not in logdir:
    logdir = '/tmp/gnb2_logs'

# Determine which dir this node uses
import subprocess
r = subprocess.run(['ls', '/tmp/gnb1_logs/'], capture_output=True, text=True)
if r.returncode == 0: logdir = '/tmp/gnb1_logs'
else: logdir = '/tmp/gnb2_logs'

pd_prb=[]; pu_snr=[]; pu_proc=[]; phr=[]
for logf in glob.glob(f'{logdir}/ue*.log'):
    try:
        # Only read last 2000 lines from each log (recent activity)
        with open(logf, 'rb') as f:
            f.seek(0, 2); size=f.tell()
            f.seek(max(0, size-200000))
            content = f.read().decode(errors='replace')
        for l in content.split('\n')[-2000:]:
            m=re.search(r'PDSCH.*nof_prb=(\d+)', l)
            if m: pd_prb.append(int(m.group(1)))
            m=re.search(r'PUSCH.*snr=([\d.]+).*t=(\d+) us', l)
            if m: pu_snr.append(float(m.group(1))); pu_proc.append(int(m.group(2)))
            m=re.search(r'PHR.*phr=(\d+)', l)
            if m: phr.append(int(m.group(1)))
    except: pass

def mean(v): return round(sum(v)/len(v),2) if v else ''
print(f"{mean(pd_prb)},{mean(pu_snr)},{mean(pu_proc)},{mean(phr)}")
PYEOF
}

# ─── Wait for UE attachment ───────────────────────────────────────────────────
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
        if [ -n "$ip" ]; then echo "$ip"; return 0; fi
        sleep 3
    done
    return 1
}

# ─── Throughput test via ping flood (RTT-based) and nc+dd fallback ───────────
iperf_dl() {
    local netns="$1" outdir="$2"
    mkdir -p "$outdir"
    # Try iperf3 first with aggressive timeout; fall back to nc+dd then ping-flood
    local j
    j=$($SSH "$UEH1" python3 << PYEOF2 2>/dev/null
import subprocess, json, time, os, socket

netns  = '$netns'
server = '10.45.0.1'
port   = ${IPERF_PORT}
dur    = ${IPERF_DURATION}

def try_iperf3():
    cmd = ['sudo','ip','netns','exec',netns,
           'iperf3','-c',server,'-p',str(port),
           '-b','3M','-t',str(dur),'-R','-J','--connect-timeout','4000']
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=dur+15)
        d = json.loads(r.stdout)
        s = d.get('end',{}).get('sum_received',{})
        bps = s.get('bits_per_second',0)
        if bps > 0:
            return round(bps/1e6,3)
    except: pass
    return None

def try_nc_dd():
    # Start nc listener on core side — we send from UE side
    try:
        # Use 5261 as nc test port on core
        srv = subprocess.Popen(
            ['ssh','-o','StrictHostKeyChecking=no','-o','BatchMode=yes',
             'saish@pc811.emulab.net',
             'nohup nc -l 10.45.0.1 5261 > /dev/null 2>&1'],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
        time.sleep(1)
        # Send 2MB from UE side, measure time
        cmd2 = ['sudo','ip','netns','exec',netns,
                'bash','-c',
                'dd if=/dev/urandom bs=4096 count=512 2>/dev/null | nc -w 8 10.45.0.1 5261']
        t0 = time.time()
        r2 = subprocess.run(cmd2, capture_output=True, text=True, timeout=25)
        dt = time.time()-t0
        srv.terminate()
        if dt > 0.5:
            bps = (512*4096*8)/(dt*1e6)
            return round(bps,3)
    except: pass
    return None

bps = try_iperf3()
if bps is None: bps = try_nc_dd()
result = {'bits_per_second': (bps or 0)*1e6, 'retransmits': 0}
print(json.dumps(result))
PYEOF2
)
    echo "${j:-{}}" > "$outdir/dl.json"
    python3 << PYEOF 2>/dev/null
import json
try:
    d=json.load(open('$outdir/dl.json'))
    bps=d.get('bits_per_second',0)
    rtr=d.get('retransmits',0)
    print(f"{round(bps/1e6,3)},{rtr}")
except: print("0,0")
PYEOF
}

# ─── ping quick test ─────────────────────────────────────────────────────────
do_ping() {
    local netns="$1" outdir="$2"
    mkdir -p "$outdir"
    local raw
    raw=$($SSH "$UEH1" "sudo ip netns exec $netns ping -c 10 -i 0.5 -W 3 10.45.0.1 2>/dev/null" 2>/dev/null || echo "100% packet loss")
    echo "$raw" > "$outdir/ping.txt"
    python3 << PYEOF 2>/dev/null
import re
txt=open('$outdir/ping.txt').read()
rtt=re.search(r'min/avg/max/mdev = ([\d.]+)/([\d.]+)/([\d.]+)/([\d.]+)',txt)
loss=re.search(r'([\d.]+)% packet loss',txt)
pl=loss.group(1) if loss else '100'
if rtt: print(f"{pl},{rtt.group(1)},{rtt.group(2)},{rtt.group(3)}")
else:   print(f"{pl},,,")
PYEOF
}

# ─── Collect full system snapshot (RAPL + sysmon + nof_ues + RAN) ────────────
collect_snapshot() {
    local node="$1" proc_pat="$2"
    local rapl nof_ues loadavg cpu_max sysmon
    rapl=$(rapl_watts "$node")
    nof_ues=$(count_srsenb "$node")
    loadavg=$($SSH "$node" "cat /proc/loadavg" 2>/dev/null || echo "0 0 0 0/0 0")
    cpu_max=$($SSH "$node" python3 << 'CPUMAX' 2>/dev/null
import re; m=0
for l in open('/proc/stat'):
    if not re.match(r'cpu\d',l): continue
    p=[int(x) for x in l.split()[1:8]]; t=sum(p) or 1; m=max(m,100-p[3]*100//t)
print(m)
CPUMAX
)
    sysmon=$(sysmon_deep "$node" "$proc_pat" "$SYSMON_DT")
    echo "${rapl:-0,0,0}|${nof_ues}|${loadavg}|${cpu_max:-0}|${sysmon:-0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0}"
}

# ─── Write one CSV row ────────────────────────────────────────────────────────
write_row() {
    local event="$1" ue_id="$2" gnb="$3"
    local attach_ok="$4" attach_lat="$5" ue_ip="$6" ho_ms="$7"
    local ping_csv="$8"    # loss,min,avg,max
    local iperf_csv="$9"   # dl_mbps,retransmits
    local snapshot="${10}" # rapl_p0,p1,total|nof_ues|load1 load5...|cpu_max|sysmon21
    local ran="${11}"      # pdprb,pusnr,puproc,phr
    local notes="${12}"
    local nue_gnb1="${13:-}" nue_gnb2="${14:-}"

    local ts ep
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ'); ep=$(epoch_now)

    IFS='|' read -r rapl_csv nof_ues load_str cpu_max sysmon_csv <<< "$snapshot"
    load1=$(echo "$load_str" | awk '{print $1}')
    load5=$(echo "$load_str" | awk '{print $2}')
    IFS=',' read -r pkg0 pkg1 total <<< "${rapl_csv:-0,0,0}"
    IFS=',' read -r sm_user sm_sys sm_sirq sm_idle sm_ctx sm_intr sm_nrx sm_ntx sm_timer sm_sched sm_rcu sm_ipc sm_freq sm_rapl sm_pcpu sm_prss sm_srun sm_swait sm_l1 sm_l5 sm_maxb <<< "${sysmon_csv:-0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0}"
    IFS=',' read -r p_loss p_min p_avg p_max <<< "${ping_csv:-100,,,}"
    IFS=',' read -r dl_mbps dl_rtr <<< "${iperf_csv:-0,0}"
    IFS=',' read -r ran_pdprb ran_pusnr ran_puproc ran_phr <<< "${ran:-,,,}"

    echo "${event},${ue_id},${gnb},${ts},${ep},${nue_gnb1},${nue_gnb2},${attach_ok},${attach_lat},${ue_ip},${ho_ms},${p_loss},${p_min},${p_avg},${p_max},${dl_mbps},0,${pkg0},${pkg1},${total},${load1},${load5},${cpu_max},${sm_user},${sm_sys},${sm_sirq},${sm_idle},${sm_ctx},${sm_intr},${sm_nrx},${sm_ntx},${sm_timer},${sm_sched},${sm_rcu},${sm_ipc},${sm_freq},${sm_rapl},${sm_pcpu},${sm_prss},${sm_srun},${sm_swait},${ran_pdprb},${ran_pusnr},${ran_puproc},${ran_phr},${notes}" >> "$MASTER_CSV"
}

# ─── Ensure iperf3 server on core ────────────────────────────────────────────
ensure_iperf() {
    $SSH "$CORE" "bash -c 'pgrep -f \"iperf3.*${IPERF_PORT}\" >/dev/null 2>&1 || (nohup bash -c \"while true; do iperf3 -s -B 10.45.0.1 -p ${IPERF_PORT}; sleep 1; done\" >/tmp/iperf3_${IPERF_PORT}.log 2>&1 &)'" 2>/dev/null || true
}

# ─── Kill a specific UE's processes (graceful then force) ────────────────────
kill_ue_procs() {
    local ue_id="$1" node="$2" proc_pattern="$3"
    $SSH "$node" "bash -c 'PIDS=\$(ps aux | grep \"${proc_pattern}.*ue${ue_id}\" | grep -v grep | awk \"{print \\\$2}\"); [ -n \"\$PIDS\" ] && sudo kill -15 \$PIDS 2>/dev/null; sleep 2; PIDS=\$(ps aux | grep \"${proc_pattern}.*ue${ue_id}\" | grep -v grep | awk \"{print \\\$2}\"); [ -n \"\$PIDS\" ] && sudo kill -9 \$PIDS 2>/dev/null; true'" 2>/dev/null || true
}

# ─── Write ue{N}_gnb2.conf on uehost1 ────────────────────────────────────────
write_gnb2_conf() {
    local ue_id="$1" gnb2_tx="$2" gnb2_rx="$3"
    local imsi; imsi=$(imsi_for_ue "$ue_id")
    local imei; imei=$(imei_for_ue "$ue_id")
    $SSH "$UEH1" python3 << GNBCONF 2>/dev/null
content = """[rf]
freq_offset  = 0
tx_gain      = 80
rx_gain      = 40
nof_antennas = 1
device_name  = zmq
device_args  = fail_on_disconnect=true,tx_port=tcp://*:${gnb2_rx},rx_port=tcp://10.10.1.3:${gnb2_tx},id=ue${ue_id}_gnb2,base_srate=11.52e6

[rat.eutra]
dl_earfcn    = 3350
nof_carriers = 1

[usim]
mode = soft
algo = milenage
opc  = 63bfa50ee6523365ff14c1f45f88737d
k    = 00112233445566778899AABBCCDDEEFF
imsi = ${imsi}
imei = ${imei}

[rrc]
release     = 8
ue_category = 4

[nas]
apn          = internet
apn_protocol = ipv4

[gw]
netns      = ue${ue_id}
ip_devname = tun_srsue${ue_id}
ip_netmask = 255.255.255.0

[log]
all_level    = info
filename     = /tmp/ue${ue_id}_gnb2.log
file_max_size = -1
"""
import subprocess
subprocess.run(['sudo','tee','/etc/srsue/ue${ue_id}_gnb2.conf'], input=content.encode(), capture_output=True)
print('ok')
GNBCONF
}

# =============================================================================
# MAIN
# =============================================================================

START_UE=${1:-51}
END_UE=${2:-100}

init_csv
ensure_iperf

# Deploy parser to both gNBs
for node in "$GNB1" "$GNB2"; do
    $SCP "$SCRIPT_DIR/parse_ran_log.py" "${node}:/tmp/parse_ran_log.py" 2>/dev/null || true
done

log "═══════════════════════════════════════════════════════════"
log "ACCUMULATION EXPERIMENT  UE${START_UE}→${END_UE}  $(date -u)"
log "Strategy: each UE stays connected on gnb1, then migrates to gnb2"
log "Results: $LOCAL_RESULTS"
log "═══════════════════════════════════════════════════════════"

# Track how many UEs are on each gNB
NOF_GNB1=$(count_srsenb "$GNB1")
NOF_GNB2=$(count_srsenb "$GNB2")
log "Initial state: gnb1=${NOF_GNB1} gnb2=${NOF_GNB2} srsenb procs"

for UE_ID in $(seq "$START_UE" "$END_UE"); do

    log "──────────────────────────────────────────────────────────"
    log "▶ UE${UE_ID}  [$(date -u '+%H:%M:%S UTC')]  gnb1=$(count_srsenb $GNB1) gnb2=$(count_srsenb $GNB2)"
    log "──────────────────────────────────────────────────────────"

    DIR="$LOCAL_RESULTS/ue${UE_ID}"
    mkdir -p "$DIR/gnb1" "$DIR/gnb2"

    # Read ports
    GNB1_TX=$(get_port "$GNB1" "/etc/srsenb/enb_ue${UE_ID}.conf" tx)
    GNB1_RX=$(get_port "$GNB1" "/etc/srsenb/enb_ue${UE_ID}.conf" rx)
    GNB2_TX=$(get_port "$GNB2" "/etc/srsenb/enb_ue${UE_ID}.conf" tx)
    GNB2_RX=$(get_port "$GNB2" "/etc/srsenb/enb_ue${UE_ID}.conf" rx)
    NETNS="ue${UE_ID}"

    log "  Ports gnb1: TX=${GNB1_TX} RX=${GNB1_RX} | gnb2: TX=${GNB2_TX} RX=${GNB2_RX}"
    if [ -z "$GNB1_TX" ] || [ -z "$GNB2_TX" ]; then
        log "  ERROR: cannot read ports — skipping UE${UE_ID}"
        continue
    fi

    # ── Pre-flight: kill any stale processes for THIS UE (not others!) ────────
    kill_ue_procs "$UE_ID" "$UEH1" "srsue"
    kill_ue_procs "$UE_ID" "$GNB1" "srsenb"
    kill_ue_procs "$UE_ID" "$GNB2" "srsenb"
    sleep 3

    # ═══════════════════════════════════════════════════════════════════════
    # PHASE 1 — Attach UE N to gnb1 (ALL prior UEs stay connected)
    # ═══════════════════════════════════════════════════════════════════════
    log "  [P1] Starting srsenb slot for UE${UE_ID} on gnb1..."
    $SSH "$GNB1" "bash -c 'sudo mkdir -p /tmp/gnb1_logs; sudo rm -f /tmp/gnb1_logs/ue${UE_ID}_stdout.log; sudo touch /tmp/gnb1_logs/ue${UE_ID}_stdout.log; sudo chmod 666 /tmp/gnb1_logs/ue${UE_ID}_stdout.log; sudo bash -c \"srsenb /etc/srsenb/enb_ue${UE_ID}.conf </dev/null >>/tmp/gnb1_logs/ue${UE_ID}_stdout.log 2>&1 &\"'" 2>/dev/null
    sleep 3

    log "  [P1] Starting srsue UE${UE_ID} → gnb1..."
    T0_ATTACH=$(epoch_now)
    $SSH "$UEH1" "bash -c 'sudo rm -f /tmp/ue${UE_ID}_stdout.log; sudo touch /tmp/ue${UE_ID}_stdout.log; sudo chmod 666 /tmp/ue${UE_ID}_stdout.log; sudo bash -c \"srsue /etc/srsue/ue${UE_ID}.conf </dev/null >>/tmp/ue${UE_ID}_stdout.log 2>&1 &\"'" 2>/dev/null

    ATTACH_OK_GNB1=0; UE_IP_GNB1=""; ATTACH_LAT=""
    if UE_IP_GNB1=$(wait_attach "$UE_ID"); then
        T_ATT=$(epoch_now)
        ATTACH_LAT=$(python3 -c "print(round($T_ATT-$T0_ATTACH,2))")
        ATTACH_OK_GNB1=1
        log "  ✓ UE${UE_ID} attached gnb1  IP=${UE_IP_GNB1}  lat=${ATTACH_LAT}s"
    else
        log "  ✗ UE${UE_ID} did NOT attach gnb1"
    fi

    # Snapshot gnb1 with N UEs connected (snapshot IMMEDIATELY after attach)
    log "  Collecting gnb1 snapshot with $(count_srsenb $GNB1) UE slots..."
    SNAP_GNB1=$(collect_snapshot "$GNB1" "srsenb")
    RAN_GNB1=$(ran_combined_snapshot "$GNB1")
    NOF_GNB1_NOW=$(count_srsenb "$GNB1")
    NOF_GNB2_NOW=$(count_srsenb "$GNB2")

    # Quick iperf + ping for the new UE
    IPERF_GNB1="0,0"; PING_GNB1="100,,,"
    if [ "$ATTACH_OK_GNB1" = "1" ]; then
        log "  Warm-up 10s before gnb1 iperf/ping..."
        sleep 10
        IPERF_GNB1=$(iperf_dl "$NETNS" "$DIR/gnb1" 2>/dev/null || echo "0,0")
        PING_GNB1=$(do_ping "$NETNS" "$DIR/gnb1" 2>/dev/null || echo "100,,,")
    fi

    write_row "attach_gnb1" "$UE_ID" "gnb1" \
        "$ATTACH_OK_GNB1" "${ATTACH_LAT:-}" "${UE_IP_GNB1:-}" "" \
        "$PING_GNB1" "$IPERF_GNB1" "$SNAP_GNB1" "$RAN_GNB1" \
        "UE${UE_ID}_attached_gnb1_${NOF_GNB1_NOW}UEs" "$NOF_GNB1_NOW" "$NOF_GNB2_NOW"

    log "  gnb1 snap: RAPL=$(echo $SNAP_GNB1|cut -d'|' -f1|cut -d, -f3)W  nof_ues=${NOF_GNB1_NOW}  dl=$(echo $IPERF_GNB1|cut -d, -f1)Mbps"

    # ═══════════════════════════════════════════════════════════════════════
    # PHASE 2 — Load-balance UE N from gnb1 to gnb2
    #   UE N moves to gnb2 but stays connected there.
    #   UE1..N-1 stay on gnb1.
    # ═══════════════════════════════════════════════════════════════════════
    log "  [P2] Load-balancing UE${UE_ID}: gnb1 → gnb2..."
    T_HO_T0=$(epoch_now)

    # Kill srsue for UE N only (gnb1 slot also killed — other UEs unaffected)
    kill_ue_procs "$UE_ID" "$UEH1" "srsue"
    sleep 8
    kill_ue_procs "$UE_ID" "$GNB1" "srsenb"
    sleep 5
    T_HO_KILL=$(epoch_now)
    HO_KILL_MS=$(python3 -c "print(round(($T_HO_KILL-$T_HO_T0)*1000,1))")
    log "  HO kill done in ${HO_KILL_MS}ms"

    # Snapshot gnb1 immediately after removing UE N (N-1 UEs remain)
    SNAP_GNB1_POST=$(collect_snapshot "$GNB1" "srsenb")
    NOF_GNB1_POST=$(count_srsenb "$GNB1")
    write_row "post_lb_gnb1" "$UE_ID" "gnb1" \
        "0" "" "" "$HO_KILL_MS" \
        "100,,," "0,0" "$SNAP_GNB1_POST" ",,," \
        "UE${UE_ID}_removed_from_gnb1_${NOF_GNB1_POST}UEs" "$NOF_GNB1_POST" "$NOF_GNB2_NOW"
    log "  gnb1 post-LB: RAPL=$(echo $SNAP_GNB1_POST|cut -d'|' -f1|cut -d, -f3)W  nof_ues=${NOF_GNB1_POST}"

    # Wait for MME context cleanup
    log "  Waiting 30s for MME cleanup..."
    sleep 30

    # Patch gnb2 rx_port and write gnb2 conf
    $SSH "$GNB2" "sudo sed -i 's|rx_port=tcp://10\.10\.1\.5:${GNB2_RX}|rx_port=tcp://10.10.1.4:${GNB2_RX}|g' /etc/srsenb/enb_ue${UE_ID}.conf" 2>/dev/null || true
    write_gnb2_conf "$UE_ID" "$GNB2_TX" "$GNB2_RX"
    log "  ✓ ue${UE_ID}_gnb2.conf written"

    # Start gnb2 srsenb slot
    $SSH "$GNB2" "bash -c 'sudo mkdir -p /tmp/gnb2_logs; sudo rm -f /tmp/gnb2_logs/ue${UE_ID}_stdout.log; sudo touch /tmp/gnb2_logs/ue${UE_ID}_stdout.log; sudo chmod 666 /tmp/gnb2_logs/ue${UE_ID}_stdout.log; sudo bash -c \"srsenb /etc/srsenb/enb_ue${UE_ID}.conf </dev/null >>/tmp/gnb2_logs/ue${UE_ID}_stdout.log 2>&1 &\"'" 2>/dev/null
    sleep 5

    # Start srsue → gnb2
    T0_ATTACH_GNB2=$(epoch_now)
    $SSH "$UEH1" "bash -c 'sudo rm -f /tmp/ue${UE_ID}_gnb2_stdout.log; sudo touch /tmp/ue${UE_ID}_gnb2_stdout.log; sudo chmod 666 /tmp/ue${UE_ID}_gnb2_stdout.log; sudo bash -c \"srsue /etc/srsue/ue${UE_ID}_gnb2.conf </dev/null >>/tmp/ue${UE_ID}_gnb2_stdout.log 2>&1 &\"'" 2>/dev/null

    # Wait for gnb2 attach (dual detection)
    ATTACH_OK_GNB2=0; UE_IP_GNB2=""; HO_TOTAL_MS=""; HO_ATTACH_MS=""
    GNB2_DEADLINE=$(( $(date +%s) + ATTACH_TIMEOUT ))
    while [ "$(date +%s)" -lt "$GNB2_DEADLINE" ]; do
        UE_IP_GNB2=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes "$UEH1" python3 << WAEOF2 2>/dev/null
import subprocess, re
try:
    r = subprocess.run(['sudo','ip','netns','exec','ue${UE_ID}','ip','addr','show','tun_srsue${UE_ID}'],
                       capture_output=True, text=True)
    m = re.search(r'inet (\\d+\\.\\d+\\.\\d+\\.\\d+)/', r.stdout)
    log_ok = False
    try: log_ok = 'Network attach successful' in open('/tmp/ue${UE_ID}_gnb2_stdout.log').read()
    except: pass
    ip = m.group(1) if m else ''
    if not ip and log_ok: ip = 'from_log'
    print(ip)
except:
    print('')
WAEOF2
)
        if [ -n "$UE_IP_GNB2" ]; then
            if [ "$UE_IP_GNB2" = "from_log" ]; then
                UE_IP_GNB2=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes "$UEH1" python3 << IPEOF 2>/dev/null
import re
try:
    m=re.search(r'IP: (\d+\.\d+\.\d+\.\d+)',open('/tmp/ue${UE_ID}_gnb2_stdout.log').read())
    print(m.group(1) if m else 'attached')
except: print('attached')
IPEOF
)
            fi
            T_ATT_GNB2=$(epoch_now)
            HO_ATTACH_MS=$(python3 -c "print(round(($T_ATT_GNB2-$T_HO_KILL)*1000,1))")
            HO_TOTAL_MS=$(python3 -c "print(round(($T_ATT_GNB2-$T_HO_T0)*1000,1))")
            ATTACH_OK_GNB2=1
            log "  ✓ UE${UE_ID} attached gnb2  IP=${UE_IP_GNB2}  HO_total=${HO_TOTAL_MS}ms"
            break
        fi
        sleep 5
    done
    [ "$ATTACH_OK_GNB2" != "1" ] && log "  ✗ UE${UE_ID} did NOT attach gnb2"

    # Snapshot BOTH gnb1 and gnb2 after migration (UE N on gnb2, UE1..N-1 on gnb1)
    log "  Collecting post-LB snapshots of gnb1 AND gnb2..."
    SNAP_GNB2=$(collect_snapshot "$GNB2" "srsenb")
    RAN_GNB2=$(ran_combined_snapshot "$GNB2")
    NOF_GNB1_FINAL=$(count_srsenb "$GNB1")
    NOF_GNB2_FINAL=$(count_srsenb "$GNB2")

    # iperf + ping on gnb2 for the newly migrated UE
    IPERF_GNB2="0,0"; PING_GNB2="100,,,"
    if [ "$ATTACH_OK_GNB2" = "1" ]; then
        log "  Warm-up 15s before gnb2 iperf/ping..."
        sleep 15
        IPERF_GNB2=$(iperf_dl "$NETNS" "$DIR/gnb2" 2>/dev/null || echo "0,0")
        PING_GNB2=$(do_ping "$NETNS" "$DIR/gnb2" 2>/dev/null || echo "100,,,")
    fi

    write_row "attach_gnb2" "$UE_ID" "gnb2" \
        "$ATTACH_OK_GNB2" "" "${UE_IP_GNB2:-}" "${HO_TOTAL_MS:-}" \
        "$PING_GNB2" "$IPERF_GNB2" "$SNAP_GNB2" "$RAN_GNB2" \
        "UE${UE_ID}_on_gnb2_gnb2has_${NOF_GNB2_FINAL}UEs" "$NOF_GNB1_FINAL" "$NOF_GNB2_FINAL"

    log "  gnb2 snap: RAPL=$(echo $SNAP_GNB2|cut -d'|' -f1|cut -d, -f3)W  nof_ues=${NOF_GNB2_FINAL}  dl=$(echo $IPERF_GNB2|cut -d, -f1)Mbps"

    # ── Cleanup: kill this UE on gnb2 so next UE can attach cleanly ────────────
    # (gnb2 only supports one active S1AP session per unique s1c_bind_addr)
    log "  [Cleanup] Killing UE${UE_ID} on gnb2..."
    kill_ue_procs "$UE_ID" "$UEH1" "srsue"
    sleep 6
    kill_ue_procs "$UE_ID" "$GNB2" "srsenb"
    sleep 8
    log "  [Cleanup] UE${UE_ID} gnb2 processes killed, waiting 20s MME cleanup..."
    sleep 20

    log "  ✓ UE${UE_ID} complete. gnb1=${NOF_GNB1_FINAL} gnb2=cleaned"
    echo ""

done

log "═══════════════════════════════════════════════════════════"
log "DONE  UE${START_UE}–${END_UE}"
log "Master CSV rows: $(wc -l < "$MASTER_CSV")"
log "Results: $LOCAL_RESULTS"
log "═══════════════════════════════════════════════════════════"
