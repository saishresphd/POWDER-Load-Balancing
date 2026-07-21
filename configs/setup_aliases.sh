#!/usr/bin/env bash
# =============================================================================
# setup_aliases.sh
#
# Add the IP aliases required so each srsenb instance on gNB1 and gNB2 binds
# GTP-U (port 2152) on a unique address.  Run once per node after every reboot.
#
# gNB1 (pc818, enp6s0f3)
#   10.10.1.2          — node primary (already present, no alias needed)
#   10.10.1.100–198    — UE2–100  (99 aliases, formula: .{98+i} for i=2..100)
#   10.10.1.200–209    — UE101–110 LB slots on gNB1 (10 aliases)
#
# gNB2 (pc802, enp6s0f3)
#   10.10.1.3          — node primary (already present, no alias needed)
#   10.10.1.210–219    — UE101–110 LB targets on gNB2 (10 aliases)
#
# Usage (run from your laptop or from the POWDER portal shell):
#   bash configs/setup_aliases.sh
# =============================================================================
set -euo pipefail

GNB1="saish@pc818.emulab.net"
GNB2="saish@pc802.emulab.net"
SSH="ssh -o StrictHostKeyChecking=no -o BatchMode=yes"

echo "============================================================"
echo " Setting up IP aliases on gNB1 (pc818)"
echo "============================================================"
$SSH "$GNB1" 'bash -s' << 'GNB1EOF'
DEV=enp6s0f3
# UE2–100: 10.10.1.{98+i} for i=2..100  →  .100 .. .198
for i in $(seq 2 100); do
  addr="10.10.1.$((98 + i))/24"
  sudo ip addr add "$addr" dev "$DEV" 2>/dev/null && echo "  added $addr" || echo "  exists $addr"
done
# UE101–110 LB slots on gNB1: 10.10.1.200–209
for j in $(seq 1 10); do
  addr="10.10.1.$((199 + j))/24"
  sudo ip addr add "$addr" dev "$DEV" 2>/dev/null && echo "  added $addr" || echo "  exists $addr"
done
echo "gNB1: alias setup complete"
ip addr show "$DEV" | grep "inet 10.10.1" | awk '{print "  " $2}'
GNB1EOF

echo ""
echo "============================================================"
echo " Setting up IP aliases on gNB2 (pc802)"
echo "============================================================"
$SSH "$GNB2" 'bash -s' << 'GNB2EOF'
DEV=enp6s0f3
# UE101–110 LB targets on gNB2: 10.10.1.210–219
for j in $(seq 1 10); do
  addr="10.10.1.$((209 + j))/24"
  sudo ip addr add "$addr" dev "$DEV" 2>/dev/null && echo "  added $addr" || echo "  exists $addr"
done
echo "gNB2: alias setup complete"
ip addr show "$DEV" | grep "inet 10.10.1" | awk '{print "  " $2}'
GNB2EOF

echo ""
echo "Done.  Aliases are active until next reboot."
echo "Re-run this script after every node reboot."
