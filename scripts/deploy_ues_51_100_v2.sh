#!/bin/bash
# deploy_ues_51_100_v2.sh — run on pc801
# Installs fixed ue51-100 configs (valid port range 50011-50501)
echo "=== Extracting ==="
cd /tmp && tar xzf ues_51_100_v2.tgz 2>/dev/null | grep -v LIBARCHIVE || true

echo "=== Installing ==="
for i in $(seq 51 100); do [ -f /tmp/ue${i}.conf ] && sudo cp /tmp/ue${i}.conf /etc/srsue/; done
echo "Installed $(ls /etc/srsue/ue*.conf | wc -l) UE configs total"
echo "Verify UE51: $(grep device_args /etc/srsue/ue51.conf)"
