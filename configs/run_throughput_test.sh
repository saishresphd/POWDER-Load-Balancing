#!/bin/bash
# ==========================================================================
#  run_throughput_test.sh  — iperf3 TCP+UDP test from all UE namespaces
#  Run on uehost1 or uehost2 after all UEs are attached
#  iperf3 server should be running on core (pc811): iperf3 -s
# ==========================================================================

CORE_IP="10.45.0.1"   # Open5GS ogstun UPF address (inside PDN)
DURATION=30           # seconds per test
PARALLEL=10           # parallel streams
LOG_DIR=/tmp/iperf_results
mkdir -p $LOG_DIR

HOSTNAME_SHORT=$(hostname | cut -d. -f1)

echo "[${HOSTNAME_SHORT}] Starting throughput tests against ${CORE_IP}"
echo "Results in ${LOG_DIR}/"

# ── TCP Test ──────────────────────────────────────────────────────────────
echo ""
echo "=== TCP Throughput (${DURATION}s) ==="
for i in $(seq 1 10); do
    NS="ue${i}"
    # Check if namespace has an IP
    if sudo ip netns exec $NS ip addr show 2>/dev/null | grep -q "inet 10.45"; then
        echo "  UE${i} TCP test..."
        sudo ip netns exec $NS iperf3 -c $CORE_IP \
            -t $DURATION -b 0 -J \
            > ${LOG_DIR}/tcp_ue${i}_${HOSTNAME_SHORT}.json 2>&1 &
    else
        echo "  UE${i}: not attached, skipping"
    fi
done
wait
echo "TCP tests complete."

# ── UDP Test ──────────────────────────────────────────────────────────────
echo ""
echo "=== UDP Throughput (${DURATION}s, 10Mbps target/UE) ==="
for i in $(seq 1 10); do
    NS="ue${i}"
    if sudo ip netns exec $NS ip addr show 2>/dev/null | grep -q "inet 10.45"; then
        echo "  UE${i} UDP test..."
        sudo ip netns exec $NS iperf3 -c $CORE_IP \
            -u -b 10M -t $DURATION -J \
            > ${LOG_DIR}/udp_ue${i}_${HOSTNAME_SHORT}.json 2>&1 &
    fi
done
wait
echo "UDP tests complete."

# ── Summarize ─────────────────────────────────────────────────────────────
echo ""
echo "=== Summary ==="
for f in ${LOG_DIR}/*.json; do
    UE_NAME=$(basename $f .json)
    if python3 -c "
import json,sys
d=json.load(open('$f'))
end=d.get('end',{})
bps=end.get('sum_received',end.get('sum',{})).get('bits_per_second',0)
print(f'  $UE_NAME: {bps/1e6:.2f} Mbps')
" 2>/dev/null; then : ; fi
done

echo ""
echo "Raw results: ${LOG_DIR}/"
