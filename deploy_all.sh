#!/bin/bash
# ==========================================================================
#  deploy_all.sh  — Master deployment script
#  Run from your local Mac: bash deploy_all.sh
#  Deploys all configs to all nodes and starts the experiment
# ==========================================================================
set -euo pipefail

CORE="saish@pc811.emulab.net"
GNB1="saish@pc818.emulab.net"
GNB2="saish@pc802.emulab.net"
UE1="saish@pc808.emulab.net"
UE2="saish@pc801.emulab.net"

SSH="ssh -o StrictHostKeyChecking=no"
SCP="scp -o StrictHostKeyChecking=no"

echo "============================================================"
echo " OpenRAN Load-Balancing Deployment"
echo " 20 UEs | 2 gNBs | 1 Core | ZMQ simulation"
echo "============================================================"

step() { echo ""; echo "━━━ STEP: $1 ━━━"; }

# ── Step 1: Check builds complete ────────────────────────────────
step "Verify srsRAN builds"
for node in $GNB1 $GNB2 $UE1 $UE2; do
    RESULT=$($SSH $node "which srsenb srsue 2>/dev/null | wc -l" 2>/dev/null || echo "0")
    echo "  $node: $RESULT binaries found"
done

# ── Step 2: Core setup ────────────────────────────────────────────
step "Configure Open5GS Core"
$SCP gen_subscribers.py $CORE:/tmp/
$SCP configs/setup_core.sh $CORE:/tmp/
$SSH $CORE "bash /tmp/setup_core.sh"

# ── Step 3: gNB1 setup ───────────────────────────────────────────
step "Configure gNB1 (pc818)"
$SCP configs/setup_gnb1.sh $GNB1:/tmp/
$SSH $GNB1 "bash /tmp/setup_gnb1.sh"

# ── Step 4: gNB2 setup ───────────────────────────────────────────
step "Configure gNB2 (pc802)"
$SCP configs/setup_gnb2.sh $GNB2:/tmp/
$SSH $GNB2 "bash /tmp/setup_gnb2.sh"

# ── Step 5: UE hosts setup ────────────────────────────────────────
step "Configure UE hosts"
$SCP configs/setup_ues_host1.sh $UE1:/tmp/
$SCP configs/start_ues_host1.sh $UE1:/tmp/
$SCP configs/loadbalance_trigger.sh $UE1:/tmp/
$SCP configs/run_throughput_test.sh $UE1:/tmp/
$SCP configs/collect_cpu_metrics.sh $UE1:/tmp/
$SSH $UE1 "bash /tmp/setup_ues_host1.sh"

$SCP configs/setup_ues_host2.sh $UE2:/tmp/
$SCP configs/start_ues_host2.sh $UE2:/tmp/
$SCP configs/collect_cpu_metrics.sh $UE2:/tmp/
$SCP configs/run_throughput_test.sh $UE2:/tmp/
$SSH $UE2 "bash /tmp/setup_ues_host2.sh"

# ── Step 6: Deploy metrics scripts everywhere ─────────────────────
step "Deploy CPU metric collectors"
for node in $CORE $GNB1 $GNB2; do
    $SCP configs/collect_cpu_metrics.sh ${node}:/tmp/
done

# ── Step 7: Start gNBs ────────────────────────────────────────────
step "Start gNB1 and gNB2"
$SSH $GNB1 "bash -c 'sudo pkill srsenb 2>/dev/null; sleep 1; sudo nohup srsenb /etc/srsenb/enb.conf > /tmp/gnb1_stdout.log 2>&1 &'"
$SSH $GNB2 "bash -c 'sudo pkill srsenb 2>/dev/null; sleep 1; sudo nohup srsenb /etc/srsenb/enb.conf > /tmp/gnb2_stdout.log 2>&1 &'"
sleep 5

# Verify gNBs connected to AMF
echo "  Checking gNB → AMF connections..."
$SSH $CORE "sudo grep 'Number of gNBs' /var/log/open5gs/amf.log | tail -3"

# ── Step 8: Start CPU metric collection on all nodes ─────────────
step "Start CPU metric collection (300s)"
for node in $CORE $GNB1 $GNB2 $UE1 $UE2; do
    $SSH $node "bash -c 'nohup bash /tmp/collect_cpu_metrics.sh 300 > /tmp/metrics_stdout.log 2>&1 &'"
done
echo "  Metrics collecting on all 5 nodes for 300s"

# ── Step 9: Start UEs ─────────────────────────────────────────────
step "Start 10 UEs on each host"
$SSH $UE1 "bash /tmp/start_ues_host1.sh"
$SSH $UE2 "bash /tmp/start_ues_host2.sh"
echo "  Waiting 30s for UEs to attach..."
sleep 30

# ── Step 10: Check UE attach status ──────────────────────────────
step "Verify UE attach status"
$SSH $UE1 "for i in \$(seq 1 10); do echo -n \"UE\${i}: \"; sudo ip netns exec ue\${i} ip addr show tun_srsue\${i} 2>/dev/null | grep 'inet ' || echo 'not attached'; done"
$SSH $UE2 "for i in \$(seq 11 20); do echo -n \"UE\${i}: \"; sudo ip netns exec ue\${i} ip addr show tun_srsue\${i} 2>/dev/null | grep 'inet ' || echo 'not attached'; done"

# ── Step 11: Start throughput tests ──────────────────────────────
step "Run throughput tests (in background)"
$SSH $CORE "bash -c 'nohup iperf3 -s > /tmp/iperf_server.log 2>&1 &'"
sleep 2
$SSH $UE1 "bash -c 'nohup bash /tmp/run_throughput_test.sh > /tmp/iperf_ue1.log 2>&1 &'"
$SSH $UE2 "bash -c 'nohup bash /tmp/run_throughput_test.sh > /tmp/iperf_ue2.log 2>&1 &'"

# ── Step 12: Start load balancer ─────────────────────────────────
step "Start load balancer"
$SSH $UE1 "bash -c 'nohup bash /tmp/loadbalance_trigger.sh > /tmp/lb_stdout.log 2>&1 &'"
echo "  Load balancer running on uehost1 (threshold=8 UEs on gNB1)"

echo ""
echo "============================================================"
echo " EXPERIMENT RUNNING"
echo " Monitor:"
echo "  gNB1 log:  ssh $GNB1 'tail -f /tmp/gnb1_stdout.log'"
echo "  AMF log:   ssh $CORE 'sudo tail -f /var/log/open5gs/amf.log'"
echo "  LB log:    ssh $UE1 'tail -f /tmp/loadbalance.log'"
echo "  Metrics:   collected to /tmp/metrics_*.csv on each node"
echo " Collect results after 5min:"
echo "  bash collect_results.sh"
echo "============================================================"
