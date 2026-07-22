#!/bin/bash
# ─── clean_logs_uehost1.sh ───────────────────────────────────────────────────
# Run ON pc808. Removes old large log files to free disk for 100 UEs.
# srsue logs for 100 UEs need ~10-20 GB of /tmp headroom.
echo "=== Disk before cleanup ==="
df -h /

echo ""
echo "=== Removing old log files in /tmp ==="
# Remove all old .log and .csv files in /tmp (not in subdirs)
sudo rm -f /tmp/ue*.log /tmp/ue*_out*.log /tmp/ue*_live.log /tmp/ue*_run.log
sudo rm -f /tmp/*.log /tmp/*.csv 2>/dev/null || true
# Clear the ue_logs subdirectory
sudo rm -f /tmp/ue_logs/*.log /tmp/ue_logs/*.csv 2>/dev/null || true

echo ""
echo "=== Disk after cleanup ==="
df -h /

echo ""
echo "=== Create fresh log directories ==="
mkdir -p /tmp/ue_logs /tmp/gnb1_logs
echo "Done"
