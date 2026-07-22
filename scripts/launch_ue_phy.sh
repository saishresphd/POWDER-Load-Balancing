#!/bin/bash
nohup bash /tmp/ran_collect/collect_ue_rsrp_snr.sh > /tmp/ran_collect/collect_ue_phy_run2.log 2>&1 &
echo "UE_PHY_PID:$!"
