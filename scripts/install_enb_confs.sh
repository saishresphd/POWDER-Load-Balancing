#!/bin/bash
# Install all enb configs from /tmp into /etc/srsenb/
START=${1:-1}
END=${2:-110}
echo "Installing enb_ue${START}-${END} configs..."
for i in $(seq $START $END); do
  if [ -f /tmp/enb_ue${i}.conf ]; then
    sudo cp /tmp/enb_ue${i}.conf /etc/srsenb/
  fi
done
echo "Installed: $(ls /etc/srsenb/enb_ue*.conf 2>/dev/null | wc -l) configs in /etc/srsenb/"
