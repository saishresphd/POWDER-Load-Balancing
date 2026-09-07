#!/bin/bash
# Push all missing files from local scripts/ to remote branch 110-ue-scale
TOKEN="${GITHUB_TOKEN:-}"   # set via: export GITHUB_TOKEN=<your_pat>
BRANCH="110-ue-scale"
REPO="saishresphd/POWDER-Load-Balancing"
SCRIPTS_DIR="/Users/saishurumkar/.bob/playground/scripts"

MISSING=(
build_master2.py build_master_v2.py build_master_v3.py build_master_v4.py
check_iperf.sh collect_gnb1_proc.py collect_power.sh collect_rich_gnb.sh
collect_rich_gnb1.py collect_rich_gnb1.sh collect_rich_ue.sh
collect_ue51_handover.sh collect_ue_rsrp_snr.sh debug_rich_gnb1.sh
deep_sysmon.py deploy_gnb2_fixed.sh deploy_gnb2_v2.sh deploy_gnb2_v3.sh
deploy_gnb2_v4.sh deploy_ues_51_100_v2.sh fill_missing_rates.sh
gnb1_sys_monitor.sh install_collect_scripts.sh launch_deep_core.sh
launch_deep_gnb1.sh launch_deep_uehost1.sh launch_fill.sh
launch_gnb1_collectors.sh launch_gnb1_proc.sh launch_power_fast.sh
launch_power_gnb1.sh launch_power_gnb1_long.sh launch_power_per_ue_rate.sh
launch_power_uehost1.sh launch_power_uehost1_long.sh launch_reparse_gnb1.sh
launch_retest.sh launch_rich_gnb1_py.sh launch_ue_phy.sh
launch_uehost1_collectors.sh measure_power_per_ue_rate.sh
measure_power_per_ue_rate_fast.sh measure_throughput_all_ues.sh
merge_per_ue_power.py merge_ran_csv.py openran_analysis_template.ipynb
plot_loss_vs_tput.py plot_power.py plot_power_long.py plot_power_vs_rate.py
plot_simple.py plot_ue_3axis.py probe_ns.sh reparse_gnb1_logs.py
restart_iperf3_server.sh retest_failed_ues.sh run_iperf_500mbps.sh
run_iperf_per_ue.sh run_ue51_lb_experiment.sh start_iperf3_core.sh
start_iperf3_server.sh start_iperf3_server_core.sh test_power_ue1.sh
udp_ramp_latency_all_ues.sh verify_iperf.sh
)

OK=0; FAIL=0
for f in "${MISSING[@]}"; do
  CONTENT=$(base64 < "$SCRIPTS_DIR/$f" | tr -d '\n')
  SHA=$(GH_TOKEN="$TOKEN" gh api \
    "https://api.github.com/repos/$REPO/contents/scripts/$f?ref=$BRANCH" \
    --jq '.sha' 2>/dev/null || echo "")
  if [ -n "$SHA" ]; then
    RESULT=$(GH_TOKEN="$TOKEN" gh api --method PUT \
      "https://api.github.com/repos/$REPO/contents/scripts/$f" \
      -f message="chore: push $f to 110-ue-scale" -f branch="$BRANCH" \
      -f content="$CONTENT" -f sha="$SHA" --jq '.content.name' 2>&1)
  else
    RESULT=$(GH_TOKEN="$TOKEN" gh api --method PUT \
      "https://api.github.com/repos/$REPO/contents/scripts/$f" \
      -f message="chore: push $f to 110-ue-scale" -f branch="$BRANCH" \
      -f content="$CONTENT" --jq '.content.name' 2>&1)
  fi
  if [[ "$RESULT" == "$f" ]]; then
    echo "✅ $f"
    ((OK++))
  else
    echo "❌ $f — $RESULT"
    ((FAIL++))
  fi
done
echo ""
echo "Done: $OK pushed, $FAIL failed"
