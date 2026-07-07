#!/bin/bash
cd /tmp/srsran4g/build && sudo make install 2>&1 | grep -E "Installing|srsran_rf_zmq|rror" | head -20
echo "INSTALL DONE on $(hostname)"
