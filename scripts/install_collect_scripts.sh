#!/bin/bash
# install_collect_scripts.sh — run on each node to set up collection env
mkdir -p /tmp/ran_collect
cd /tmp

# Extract (ignore macOS extended attribute warnings)
tar xzf ran_collect_scripts.tgz 2>&1 | grep -v LIBARCHIVE || true

# Copy all scripts into /tmp/ran_collect
for f in scripts/collect_system_metrics.sh scripts/collect_gnb_metrics.sh \
          scripts/run_iperf_ramp.sh scripts/orchestrate_collection.sh \
          scripts/setup_iperf_server.sh scripts/check_all_ues.sh \
          scripts/start_ues_51_100.sh; do
  [ -f "$f" ] && cp "$f" /tmp/ran_collect/ && echo "Installed $f"
done

chmod +x /tmp/ran_collect/*.sh 2>/dev/null || true
echo "Done. Files in /tmp/ran_collect:"
ls /tmp/ran_collect/
