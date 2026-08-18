# gnb1 UE50 RAN log (raw parsed CSV)

`gnb1_ue50_ran_metrics.csv` is 436 MB (5.37M rows) and exceeds GitHub limits.

## Retrieve from POWDER
```bash
# On gnb1 (pc818.emulab.net), the parsed CSV is at:
scp saish@pc818.emulab.net:/tmp/gnb1_ue50_ran_metrics.csv ./

# Or re-parse from the original srsRAN log:
scp saish@pc818.emulab.net:/tmp/gnb1_logs/ue50.log ./
python3 scripts/parse_ran_log.py ue50.log gnb1_ue50_ran_metrics.csv
```

## Column schema
Same as `results/ue50_experiment/ran_pdsch_pusch_phr_bsr.csv` + full PUCCH rows.

## Row counts
- PUCCH: 5,333,204  (one per ms polling interval — use ran_pucch_sampled.csv instead)
- PDSCH: 16,077
- PUSCH: 13,232
- PHR:      894
- BSR:    2,469

## Use the pre-processed files in this repo instead:
- `results/ue50_experiment/ran_pdsch_pusch_phr_bsr.csv`  (18,060 + 13,398 + 943 + 2,640 rows)
- `results/ue50_experiment/ran_pucch_sampled.csv`         (1 row/second, CQI-preferred)
