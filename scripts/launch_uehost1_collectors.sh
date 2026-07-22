#!/bin/bash
chmod +x /tmp/ran_collect/collect_ue_rsrp_snr.sh /tmp/ran_collect/udp_ramp_latency_all_ues.sh
# First collect static UE PHY metrics (fast, ~10s)
nohup bash /tmp/ran_collect/collect_ue_rsrp_snr.sh > /tmp/ran_collect/collect_ue_phy_run.log 2>&1 &
echo "UE_PHY_PID:$!"
sleep 15
# Then launch the full UDP ramp + latency test (long running, ~49 UEs x ~120s each = ~100 min)
nohup bash /tmp/ran_collect/udp_ramp_latency_all_ues.sh > /tmp/ran_collect/udp_ramp_run.log 2>&1 &
echo "UDP_RAMP_PID:$!"
echo "STARTED"
