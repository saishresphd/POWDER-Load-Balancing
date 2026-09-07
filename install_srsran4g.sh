#!/bin/bash
# Install srsRAN 4G 23.11 with ZMQ from source on Ubuntu 22.04
# Compatible with Open5GS 5GC over N2/N3

set -e
LOG=/tmp/srsran_install.log
exec > >(tee -a $LOG) 2>&1

echo "[$(date)] Starting srsRAN 4G 23.11 install on $(hostname)"

# ── Kill running srsRAN processes ─────────────────────────────────
sudo pkill -9 gnb srsgnb srsenb srsue srsue_zmq srsue_zmq23 2>/dev/null || true
sleep 1

# ── Remove old srsRAN Project binaries ────────────────────────────
for b in gnb srsgnb srsdu srscu srscucp srscuup srsdu_low ru_emulator srsue_zmq srsue_zmq23; do
    sudo rm -f /usr/local/bin/$b
done
sudo rm -rf /usr/local/share/srsran
sudo rm -f /tmp/srsran-4g /tmp/srsran-4g-new 2>/dev/null || true

# Remove old apt srsue/srsenb if any
sudo apt-get remove -y srsue srsenb srsran srsran-core srsran-dev 2>/dev/null || true

# ── Install build dependencies ────────────────────────────────────
echo "[$(date)] Installing dependencies..."
sudo apt-get update -qq
sudo apt-get install -y \
    build-essential cmake git \
    libfftw3-dev libmbedtls-dev \
    libboost-program-options-dev libboost-system-dev \
    libconfig++-dev libsctp-dev libzmq3-dev \
    libliquid-dev libuhd-dev uhd-host \
    libspdlog-dev libyaml-cpp-dev \
    python3-pip pkg-config 2>&1 | tail -5

# ── Clone srsRAN 4G release_23_11 ────────────────────────────────
echo "[$(date)] Cloning srsRAN 4G release_23_11..."
cd /tmp
rm -rf srsran4g
git clone --depth=1 --branch release_23_11 \
    https://github.com/srsran/srsRAN_4G.git srsran4g 2>&1 | tail -3

# ── Build ─────────────────────────────────────────────────────────
echo "[$(date)] Building ($(nproc) cores)..."
cd /tmp/srsran4g
mkdir -p build && cd build
cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DENABLE_ZEROMQ=ON \
    -DENABLE_UHD=ON \
    -DENABLE_BLADERF=OFF \
    -DENABLE_SRSMBMS=OFF \
    2>&1 | tail -5

make -j$(nproc) srsenb srsue srsgnb 2>&1 | tail -10

# ── Install ───────────────────────────────────────────────────────
echo "[$(date)] Installing binaries..."
sudo make install 2>&1 | tail -5
sudo ldconfig

# ── Verify ────────────────────────────────────────────────────────
echo "[$(date)] Verifying install..."
srsenb --version 2>/dev/null || echo "srsenb not found (may be named srsgnb)"
srsue --version 2>/dev/null || echo "srsue check..."
srsue 2>&1 | grep "Supported RF" | head -2

echo "[$(date)] DONE on $(hostname)"
