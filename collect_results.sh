#!/bin/bash
# ==========================================================================
#  collect_results.sh  — Pull all experiment results to local machine
#  Run from your Mac after the experiment (5+ minutes after deploy_all.sh)
# ==========================================================================
set -euo pipefail

CORE="saish@pc811.emulab.net"
GNB1="saish@pc818.emulab.net"
GNB2="saish@pc802.emulab.net"
UE1="saish@pc808.emulab.net"
UE2="saish@pc801.emulab.net"

SCP="scp -o StrictHostKeyChecking=no"
SSH="ssh -o StrictHostKeyChecking=no"

RESULTS_DIR="./results_$(date +%Y%m%d_%H%M%S)"
mkdir -p $RESULTS_DIR/{metrics,iperf,logs}

echo "Collecting results to $RESULTS_DIR/"

# ── CPU Metrics ───────────────────────────────────────────────────────────
echo "Pulling CPU metrics..."
for node_label in "core:$CORE" "gnb1:$GNB1" "gnb2:$GNB2" "uehost1:$UE1" "uehost2:$UE2"; do
    label="${node_label%%:*}"
    host="${node_label##*:}"
    $SCP "${host}:/tmp/metrics_*.csv" "${RESULTS_DIR}/metrics/${label}_cpu.csv" 2>/dev/null || \
        echo "  WARN: no metrics from $label"
done

# ── iperf3 Results ────────────────────────────────────────────────────────
echo "Pulling iperf3 results..."
$SCP "${UE1}:/tmp/iperf_results/*.json" "${RESULTS_DIR}/iperf/" 2>/dev/null || true
$SCP "${UE2}:/tmp/iperf_results/*.json" "${RESULTS_DIR}/iperf/" 2>/dev/null || true

# ── Load Balancer Log ─────────────────────────────────────────────────────
echo "Pulling load balancer log..."
$SCP "${UE1}:/tmp/loadbalance.log" "${RESULTS_DIR}/logs/" 2>/dev/null || true

# ── AMF/gNB Logs ─────────────────────────────────────────────────────────
echo "Pulling AMF and gNB logs..."
$SSH $CORE "sudo cat /var/log/open5gs/amf.log" > "${RESULTS_DIR}/logs/amf.log" 2>/dev/null || true
$SCP "${GNB1}:/tmp/gnb1_stdout.log" "${RESULTS_DIR}/logs/" 2>/dev/null || true
$SCP "${GNB2}:/tmp/gnb2_stdout.log" "${RESULTS_DIR}/logs/" 2>/dev/null || true

# ── Generate Summary CSV ──────────────────────────────────────────────────
echo "Generating summary..."
python3 << 'PYEOF'
import os, json, glob, csv
from pathlib import Path

results = Path("RESULTS_PLACEHOLDER")

# Parse iperf JSON results
print("\n=== THROUGHPUT SUMMARY ===")
for f in sorted(glob.glob(str(results / "iperf/*.json"))):
    try:
        d = json.load(open(f))
        end = d.get('end', {})
        bps = end.get('sum_received', end.get('sum', {})).get('bits_per_second', 0)
        name = os.path.basename(f).replace('.json','')
        print(f"  {name:40s}: {bps/1e6:7.2f} Mbps")
    except Exception as e:
        print(f"  {os.path.basename(f)}: parse error ({e})")

# Parse CPU CSV
print("\n=== CPU SUMMARY (peak/avg) ===")
for f in sorted(glob.glob(str(results / "metrics/*.csv"))):
    try:
        rows = list(csv.DictReader(open(f)))
        if rows:
            cpus = [float(r.get('cpu_total_pct', 0)) for r in rows]
            gnb  = [float(r.get('gnb_cpu_pct', 0)) for r in rows]
            node = rows[0].get('hostname', os.path.basename(f))
            print(f"  {node:30s}: avg CPU={sum(cpus)/len(cpus):.1f}% peak={max(cpus):.1f}% gnb_avg={sum(gnb)/len(gnb):.1f}%")
    except Exception as e:
        print(f"  {os.path.basename(f)}: {e}")
PYEOF

# Fix path in python script
sed -i "s|RESULTS_PLACEHOLDER|${RESULTS_DIR}|g" /dev/stdin << 'NOOP'
NOOP

echo ""
echo "Results saved to: $RESULTS_DIR"
ls -la $RESULTS_DIR/
