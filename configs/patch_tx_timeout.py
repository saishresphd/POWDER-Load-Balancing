#!/usr/bin/env python3
# Revert tx_opts.trx_timeout_ms — it breaks gNB TX REP/UE RX REQ handshake
filepath = "/tmp/srsran4g/lib/src/phy/rf/rf_zmq_imp.c"
with open(filepath, "r") as f:
    content = f.read()

# Remove the tx_opts line we added; keep rx_opts line untouched
old = "      rx_opts.trx_timeout_ms = ZMQ_TIMEOUT_MS;\n      tx_opts.trx_timeout_ms = ZMQ_TIMEOUT_MS;\n"
new = "      rx_opts.trx_timeout_ms = ZMQ_TIMEOUT_MS;\n"

if old in content:
    content = content.replace(old, new)
    with open(filepath, "w") as f:
        f.write(content)
    print("PATCH OK — removed tx_opts.trx_timeout_ms")
else:
    # Check what's actually there
    for i, line in enumerate(content.split("\n")):
        if "trx_timeout_ms" in line and "ZMQ_TIMEOUT_MS" in line:
            print(f"LINE {i+1}: {line}")
