#!/bin/bash
# =============================================================================
# check_status.sh — Check how many UEs are attached
# =============================================================================

CORE=saish@pc811.emulab.net
UH1=saish@pc808.emulab.net
UH2=saish@pc801.emulab.net
GNB1=saish@pc818.emulab.net
GNB2=saish@pc802.emulab.net

echo "============================================================"
echo "  CORE: MME log (last 30 lines)"
echo "============================================================"
ssh $CORE 'sudo tail -30 /var/log/open5gs/mme.log'

echo ""
echo "============================================================"
echo "  gNB1: Connected eNB instances"
echo "============================================================"
ssh $GNB1 'bash -s' << 'EOF'
echo "Running srsenb instances: $(pgrep -c srsenb 2>/dev/null || echo 0)"
grep -l "S1Setup.*completed" /tmp/gnb1_logs/*_stdout.log 2>/dev/null \
  | sed 's|.*ue||;s|_stdout.*||' \
  | sort -n \
  | xargs -I{} echo "  enb_ue{}: MME connected"
EOF

echo ""
echo "============================================================"
echo "  gNB2: Connected eNB instances"
echo "============================================================"
ssh $GNB2 'bash -s' << 'EOF'
echo "Running srsenb instances: $(pgrep -c srsenb 2>/dev/null || echo 0)"
grep -l "S1Setup.*completed" /tmp/gnb2_logs/*_stdout.log 2>/dev/null \
  | sed 's|.*ue||;s|_stdout.*||' \
  | sort -n \
  | xargs -I{} echo "  enb_ue{}: MME connected"
EOF

echo ""
echo "============================================================"
echo "  uehost1: UE1-10 tunnel interfaces"
echo "============================================================"
ssh $UH1 'bash -s' << 'EOF'
attached=0
for i in $(seq 1 10); do
  # tun is in default namespace (no netns= in config)
  ip=$(ip addr show tun_srsue${i} 2>/dev/null | grep "inet " | awk '{print $2}')
  if [ -n "$ip" ]; then
    echo "  UE${i}: ATTACHED  tun_srsue${i} = $ip"
    attached=$((attached+1))
  else
    echo "  UE${i}: not attached"
  fi
done
echo "  uehost1 total attached: $attached/10"
EOF

echo ""
echo "============================================================"
echo "  uehost2: UE11-20 tunnel interfaces"
echo "============================================================"
ssh $UH2 'bash -s' << 'EOF'
attached=0
for i in $(seq 11 20); do
  ip=$(ip addr show tun_srsue${i} 2>/dev/null | grep "inet " | awk '{print $2}')
  if [ -n "$ip" ]; then
    echo "  UE${i}: ATTACHED  tun_srsue${i} = $ip"
    attached=$((attached+1))
  else
    echo "  UE${i}: not attached"
  fi
done
echo "  uehost2 total attached: $attached/10"
EOF

echo ""
echo "============================================================"
echo "  MME: Total Attach/Active sessions"
echo "============================================================"
ssh $CORE 'bash -s' << 'EOF'
echo "Attach Complete events:"
sudo grep "Attach complete" /var/log/open5gs/mme.log | wc -l
echo "Active sessions (SMF):"
sudo grep "Create Session" /var/log/open5gs/smf.log 2>/dev/null | wc -l || \
sudo grep "Session" /var/log/open5gs/sgwc.log 2>/dev/null | wc -l
EOF
