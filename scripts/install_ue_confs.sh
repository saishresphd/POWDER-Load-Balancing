#!/bin/bash
# Install all UE configs from /tmp into /etc/srsue/
echo "Installing UE configs..."
for i in $(seq 1 100); do
  if [ -f /tmp/ue${i}.conf ]; then
    sudo cp /tmp/ue${i}.conf /etc/srsue/
  fi
done
echo "Installed: $(ls /etc/srsue/ue*.conf 2>/dev/null | wc -l) configs in /etc/srsue/"
