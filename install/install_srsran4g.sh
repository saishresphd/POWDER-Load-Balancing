#!/bin/bash
# install_srsran4g.sh — Build srsRAN 4G v23.4 from source with ZMQ
# Run on: gnb1 (pc818), gnb2 (pc802), uehost1 (pc808), uehost2 (pc801)
# Usage: bash install_srsran4g.sh
set -e

echo "=== Installing build dependencies ==="
sudo apt update
sudo apt install -y \
  cmake make gcc g++ pkg-config \
  libfftw3-dev libmbedtls-dev libsctp-dev \
  libconfig++-dev libboost-program-options-dev \
  libzmq3-dev libuhd-dev uhd-host \
  python3 git

echo "=== Cloning srsRAN 4G v23.4 ==="
cd /tmp
rm -rf srsran4g
git clone https://github.com/srsran/srsRAN_4G.git srsran4g
cd srsran4g
git checkout eea87b1    # v23.4.0 pinned commit

echo "=== Building with ZMQ enabled ==="
mkdir build && cd build
cmake .. \
  -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_WERROR=OFF \
  -DENABLE_ZMQ=ON \
  -DENABLE_UHD=OFF
make -j$(nproc) srsenb srsue srsran_rf_zmq

echo "=== Installing ==="
sudo make install
sudo ldconfig

echo "=== Installing default config files ==="
sudo srsran_install_configs.sh service

echo "=== Verifying ==="
srsenb --version
srsue  --version
ldconfig -p | grep libsrsran_rf_zmq

echo ""
echo "✓ srsRAN 4G installed successfully on $(hostname -s)"
