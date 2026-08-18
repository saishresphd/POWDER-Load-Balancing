#!/usr/bin/env python3
"""
fix_ue_configs_51_100_v2.py
Run LOCALLY — reads gnb1 ports and generates + applies fixes on uehost1 via SSH.
"""

import subprocess, sys

# gnb1 port table (read from gnb1 configs)
# format: n -> (gnb1_tx, gnb1_rx)
GNB1_PORTS = {
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

GNB1_IP = "10.10.1.2"
UEH1 = "saish@pc808.emulab.net"

start = int(sys.argv[1]) if len(sys.argv) > 1 else 51
end   = int(sys.argv[2]) if len(sys.argv) > 2 else 100

print(f"Fixing ue{start}..ue{end} srsue configs on uehost1...")

# Build a python script that fixes all confs in one SSH call
fix_lines = ["import re"]
for n in range(start, end + 1):
    if n not in GNB1_PORTS:
        continue
    gnb1_tx, gnb1_rx = GNB1_PORTS[n]
    ue_tx = gnb1_rx          # UE binds this port; gnb1 connects to uehost1:this
    ue_rx = f"tcp://{GNB1_IP}:{gnb1_tx}"  # UE connects to gnb1's tx
    new_args = (f"fail_on_disconnect=true,"
                f"tx_port=tcp://*:{ue_tx},"
                f"rx_port={ue_rx},"
                f"id=ue{n},"
                f"base_srate=11.52e6")
    conf_path = f"/etc/srsue/ue{n}.conf"
    fix_lines.append(
        f"conf=open('{conf_path}').read();"
        f"conf2=re.sub(r'device_args\\s*=.*', 'device_args  = {new_args}', conf);"
        f"open('{conf_path}','w').write(conf2);"
        f"print('UE{n}: tx={ue_tx} rx={ue_rx}')"
    )

fix_script = "\n".join(fix_lines)

# Upload fix script to uehost1
script_path = "/tmp/fix_ue_gnb1_confs.py"
result = subprocess.run(
    ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "BatchMode=yes", UEH1,
     f"sudo python3 -c '{fix_script}' 2>&1"],
    capture_output=True, text=True, timeout=120
)
print(result.stdout)
if result.stderr:
    print("STDERR:", result.stderr[:500])
print(f"Exit code: {result.returncode}")
