#!/bin/bash
# Install ue101-110 configs from /tmp into /etc/srsue/
for i in $(seq 101 110); do
  if [ -f /tmp/ue${i}.conf ]; then
    sudo cp /tmp/ue${i}.conf /etc/srsue/
  fi
done
echo "Installed: $(ls /etc/srsue/ue*.conf 2>/dev/null | wc -l) configs in /etc/srsue/"
