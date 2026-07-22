#!/bin/bash
# start_iperf3_server_core.sh
# Ensures a single iperf3 server is running on port 5201 on the core.
# Kills any stale instances first, then starts fresh with --daemon.

pkill -f "iperf3 -s" 2>/dev/null || true
sleep 1

iperf3 -s -p 5201 --daemon --logfile /tmp/iperf3_5201.log
echo "[core] iperf3 server started on port 5201, PID $(pgrep -f 'iperf3 -s')"
