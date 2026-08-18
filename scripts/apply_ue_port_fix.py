#!/usr/bin/env python3
"""
Fixes UE51-100 srsue device_args on uehost1 to match gnb1 ZMQ port expectations.
Run with: sudo python3 /tmp/apply_fix.py
"""
import re

GNB1_IP = "10.10.1.2"

# gnb1 port table: n -> (gnb1_tx_port, gnb1_rx_port)
# gnb1 tx = port gnb1 binds and broadcasts on (UE must connect to this to RX)
# gnb1 rx = port gnb1 connects TO on uehost1 (UE must bind and TX on this)
PORTS = {
    51: (40510, 40511), 52: (40520, 40521), 53: (40530, 40531),
    54: (40540, 40541), 55: (40550, 40551), 56: (40560, 40561),
    57: (40570, 40571), 58: (40580, 40581), 59: (40590, 40591),
    60: (40600, 40601), 61: (40610, 40611), 62: (40620, 40621),
    63: (40630, 40631), 64: (40640, 40641), 65: (40650, 40651),
    66: (40660, 40661), 67: (40670, 40671), 68: (40680, 40681),
    69: (40690, 40691), 70: (40700, 40701), 71: (40710, 40711),
    72: (40720, 40721), 73: (40730, 40731), 74: (40740, 40741),
    75: (40750, 40751), 76: (40760, 40761), 77: (40770, 40771),
    78: (40780, 40781), 79: (40790, 40791), 80: (40800, 40801),
    81: (40810, 40811), 82: (40820, 40821), 83: (40830, 40831),
    84: (40840, 40841), 85: (40850, 40851), 86: (40860, 40861),
    87: (40870, 40871), 88: (40880, 40881), 89: (40890, 40891),
    90: (40900, 40901), 91: (40910, 40911), 92: (40920, 40921),
    93: (40930, 40931), 94: (40940, 40941), 95: (40950, 40951),
    96: (40960, 40961), 97: (40970, 40971), 98: (40980, 40981),
    99: (40990, 40991), 100: (41000, 41001),
}

fixed = 0
for n, (gnb1_tx, gnb1_rx) in PORTS.items():
    # UE tx_port = gnb1_rx  (UE binds this; gnb1 connects TO uehost1:gnb1_rx)
    # UE rx_port = tcp://gnb1_ip:gnb1_tx  (UE connects to gnb1's transmit socket)
    ue_tx = gnb1_rx
    ue_rx = f"tcp://{GNB1_IP}:{gnb1_tx}"
    new_args = (
        f"fail_on_disconnect=true,"
        f"tx_port=tcp://*:{ue_tx},"
        f"rx_port={ue_rx},"
        f"id=ue{n},"
        f"base_srate=11.52e6"
    )
    conf_path = f"/etc/srsue/ue{n}.conf"
    try:
        conf = open(conf_path).read()
        new_conf = re.sub(r"device_args\s*=.*", f"device_args  = {new_args}", conf)
        open(conf_path, "w").write(new_conf)
        print(f"OK UE{n}: tx=*:{ue_tx}  rx={ue_rx}")
        fixed += 1
    except Exception as e:
        print(f"ERR UE{n}: {e}")

print(f"\nFixed {fixed}/50 UE configs.")
