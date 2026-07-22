#!/bin/bash
# ============================================================
# setup_iperf_server.sh  — run on core (pc811)
# Starts iperf3 server reachable from all UE namespaces (10.45.0.1)
# ============================================================
echo "=== Installing iperf3 ==="
sudo apt-get install -y iperf3 -qq 2>/dev/null

echo "=== Starting iperf3 server on 0.0.0.0:5201 ==="
pkill iperf3 2>/dev/null || true
sleep 1
# Run as daemon, allow multiple clients
sudo nohup iperf3 -s -D --logfile /tmp/iperf3_server.log 2>&1
sleep 2

# Verify
if pgrep iperf3 > /dev/null; then
    echo "iperf3 server running: $(pgrep iperf3)"
else
    echo "ERROR: iperf3 server failed to start"
    exit 1
fi

# Check ogstun interface exists (UE packets come in via 10.45.0.0/16)
ip addr show ogstun 2>/dev/null && echo "ogstun OK" || echo "WARNING: ogstun not found"
echo "Core ready for iperf tests"
