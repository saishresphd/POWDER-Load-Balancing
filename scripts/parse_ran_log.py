#!/usr/bin/env python3
"""
parse_ran_log.py
Parse srsRAN 4G eNB log file into per-TTI RAN metrics CSV.

Extracts from each TTI (per-millisecond):
  PDSCH : timestamp, tti, rnti, nof_prb, nof_re, tbs, mod_order, rv
  PUSCH : timestamp, tti, rnti, rb_start, rb_len, nof_re, tbs, mod_order, rv, crc, snr_db, epre_dbfs, ta_us, cfo_hz, proc_us
  PUCCH : timestamp, tti, rnti, format, snr_db, corr, sr, cqi, ack, dmrs_corr
  PHR   : timestamp, tti, rnti, phr_db
  BSR   : timestamp, tti, rnti, lc0, lc1, lc2, lc3

Output: one row per event (event_type column distinguishes them).
"""
import re, sys, csv
from pathlib import Path

LOG  = sys.argv[1]
OUT  = sys.argv[2]

PDSCH_RE = re.compile(
    r'^(\S+)\s+\[PHY\d+\s*\].*\[\s*(\d+)\]\s+PDSCH:\s+cc=\d+,\s+rnti=(0x\w+),\s+nof_prb=(\d+),\s+nof_re=(\d+),\s+tbs=\{([\d,]+)\},\s+mod=\{(\d+)\},\s+rv=\{(\d+)\}')
PUSCH_RE = re.compile(
    r'^(\S+)\s+\[PHY\d+\s*\].*\[\s*(\d+)\]\s+PUSCH:\s+cc=\d+,\s+rnti=(0x\w+),\s+rb=\((\d+),(\d+)\),\s+nof_re=(\d+),\s+tbs=(\d+),\s+mod=(\d+),\s+rv=(\d+),\s+crc=(\w+),\s+avg_iter=([\d.]+),\s+snr=([\d.inf-]+)\s+dB,\s+epre=([\d.inf-]+)\s+dBfs,\s+ta=([\d.inf-]+)\s+us,\s+cfo=([\d.inf-]+)\s+hz,\s+t=(\d+)\s+us')
PUCCH_RE = re.compile(
    r'^(\S+)\s+\[PHY\d+\s*\].*\[\s*(\d+)\]\s+PUCCH:\s+cc=\d+;\s+rnti=(0x\w+),\s+f=(\S+),.*snr=([\S]+)\s+dB,\s+corr=([\S]+)(?:,\s+sr=(\w+))?(?:,\s+cqi=(\d+))?(?:.*ack=(\d+))?')
PHR_RE   = re.compile(
    r'^(\S+)\s+\[MAC\s*\].*\[\s*(\d+)\]\s+(0x\w+)\s+UL PHR:\s+ph=([\d.]+)')
BSR_RE   = re.compile(
    r'^(\S+)\s+\[MAC\s*\].*\[\s*(\d+)\]\s+(0x\w+)\s+UL.*LBSR:\s+b=(\d+)\s+(\d+)\s+(\d+)\s+(\d+)')

COLS = [
    'timestamp','tti','rnti','event_type',
    # PDSCH
    'pdsch_nof_prb','pdsch_nof_re','pdsch_tbs','pdsch_mod','pdsch_rv',
    # PUSCH
    'pusch_rb_start','pusch_rb_len','pusch_nof_re','pusch_tbs',
    'pusch_mod','pusch_rv','pusch_crc',
    'pusch_snr_db','pusch_epre_dbfs','pusch_ta_us','pusch_cfo_hz','pusch_proc_us',
    # PUCCH
    'pucch_format','pucch_snr_db','pucch_corr','pucch_sr','pucch_cqi','pucch_ack',
    # PHR / BSR
    'phr_db',
    'bsr_lc0','bsr_lc1','bsr_lc2','bsr_lc3',
]

count = {'PDSCH':0,'PUSCH':0,'PUCCH':0,'PHR':0,'BSR':0}

with open(LOG, errors='replace') as fin, open(OUT, 'w', newline='') as fout:
    w = csv.DictWriter(fout, fieldnames=COLS, extrasaction='ignore')
    w.writeheader()

    for line in fin:
        r = {k:'' for k in COLS}

        m = PDSCH_RE.match(line)
        if m:
            r.update({'timestamp':m.group(1),'tti':m.group(2),'rnti':m.group(3),
                      'event_type':'PDSCH',
                      'pdsch_nof_prb':m.group(4),'pdsch_nof_re':m.group(5),
                      'pdsch_tbs':m.group(6).replace(',','+'),
                      'pdsch_mod':m.group(7),'pdsch_rv':m.group(8)})
            w.writerow(r); count['PDSCH']+=1; continue

        m = PUSCH_RE.match(line)
        if m:
            r.update({'timestamp':m.group(1),'tti':m.group(2),'rnti':m.group(3),
                      'event_type':'PUSCH',
                      'pusch_rb_start':m.group(4),'pusch_rb_len':m.group(5),
                      'pusch_nof_re':m.group(6),'pusch_tbs':m.group(7),
                      'pusch_mod':m.group(8),'pusch_rv':m.group(9),
                      'pusch_crc':m.group(10),
                      'pusch_snr_db':m.group(12),'pusch_epre_dbfs':m.group(13),
                      'pusch_ta_us':m.group(14),'pusch_cfo_hz':m.group(15),
                      'pusch_proc_us':m.group(16)})
            w.writerow(r); count['PUSCH']+=1; continue

        m = PUCCH_RE.match(line)
        if m:
            r.update({'timestamp':m.group(1),'tti':m.group(2),'rnti':m.group(3),
                      'event_type':'PUCCH',
                      'pucch_format':m.group(4),
                      'pucch_snr_db':m.group(5),'pucch_corr':m.group(6),
                      'pucch_sr':m.group(7) or '',
                      'pucch_cqi':m.group(8) or '',
                      'pucch_ack':m.group(9) or ''})
            w.writerow(r); count['PUCCH']+=1; continue

        m = PHR_RE.match(line)
        if m:
            r.update({'timestamp':m.group(1),'tti':m.group(2),'rnti':m.group(3),
                      'event_type':'PHR','phr_db':m.group(4)})
            w.writerow(r); count['PHR']+=1; continue

        m = BSR_RE.match(line)
        if m:
            r.update({'timestamp':m.group(1),'tti':m.group(2),'rnti':m.group(3),
                      'event_type':'BSR',
                      'bsr_lc0':m.group(4),'bsr_lc1':m.group(5),
                      'bsr_lc2':m.group(6),'bsr_lc3':m.group(7)})
            w.writerow(r); count['BSR']+=1; continue

print(f"Done. {count}")
