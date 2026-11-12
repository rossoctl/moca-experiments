# E16 long rung: VM memory against age -- resident-inf, lowduty, N=256, 3 h window

resident-inf, lowduty, N=256, warm-up 600 s, window 10800 s. Verdict (information, not a ladder rung): holds=True holds_abs=True, p95 excess 107 ms vs limit 395 ms.

1723 VMs; ages to 185 min. Median VM memory by age: 0 min 61.9 MiB, 20 min 118.4 MiB, 60 min 142.4 MiB, 120 min 147.9 MiB, 180 min 147.1 MiB.

Growth of the median VM from 20 min of age (VMs seen at both ages; < 20 VMs is too few):

- 20 to 60 min: 26.5% over 300 VMs (those VMs' median 112.6 MiB at 20 min, 142.4 MiB at 60 min)
- 20 to 120 min: 67.2% over 143 VMs (those VMs' median 88.5 MiB at 20 min, 147.9 MiB at 120 min)
- 20 to 180 min: 90.9% over 63 VMs (those VMs' median 77.0 MiB at 20 min, 147.1 MiB at 180 min)
Population medians (every VM seen in the bin) are the level reading; the paired %% is inflated because long-lived VMs are lighter at 20 min than the population.

VM life (worker.log): 1736 VMs, 1479 destroyed in the run, 257 alive at its end.
- age at session end: median 2.0 min, p90 52.1, max 186.5
- last Exec to destroy: median 0.0 min, p90 0.0, max 0.0 (n=1478)
- last Exec to destroy, VMs that reached 50 min of age: median 0.0 min, p90 0.0 (n=152)
- alive at run end: age median 103.3 min, max 189.9

VM memory at 2.5 h:
- VMs aged 150 min: 104 VMs, median 152.7 MiB, p95 231.3, max 309.4
- all VMs alive at rung time 2.5 h (t=9000 s): 256 VMs, median 148.9 MiB, p95 233.1, max 292.0, sum 36.5 GiB

| age (min) | VMs | median MiB | p95 MiB |
|---|---|---|---|
| 0 | 1723 | 61.9 | 172.4 |
| 5 | 734 | 94.6 | 195.5 |
| 10 | 602 | 109.2 | 201.9 |
| 15 | 531 | 114.4 | 208.3 |
| 20 | 497 | 118.4 | 208.6 |
| 25 | 476 | 121.5 | 212.2 |
| 30 | 447 | 128.4 | 212.2 |
| 35 | 398 | 135.3 | 212.2 |
| 40 | 376 | 136.8 | 214.1 |
| 45 | 353 | 137.3 | 213.1 |
| 50 | 329 | 140.1 | 217.7 |
| 55 | 314 | 141.9 | 217.7 |
| 60 | 300 | 142.4 | 214.9 |
| 65 | 282 | 143.9 | 215.8 |
| 70 | 262 | 143.9 | 215.8 |
| 75 | 250 | 145.7 | 219.5 |
| 80 | 238 | 147.0 | 227.8 |
| 85 | 223 | 146.8 | 228.0 |
| 90 | 210 | 147.1 | 228.0 |
| 95 | 193 | 148.3 | 232.3 |
| 100 | 181 | 148.3 | 233.2 |
| 105 | 166 | 151.7 | 233.1 |
| 110 | 156 | 149.2 | 234.7 |
| 115 | 148 | 149.1 | 232.9 |
| 120 | 143 | 147.9 | 230.2 |
| 125 | 137 | 148.2 | 231.7 |
| 130 | 131 | 146.0 | 230.4 |
| 135 | 124 | 146.0 | 231.3 |
| 140 | 117 | 146.1 | 231.4 |
| 145 | 111 | 149.1 | 231.5 |
| 150 | 104 | 152.7 | 231.3 |
| 155 | 96 | 152.7 | 238.5 |
| 160 | 90 | 150.7 | 231.3 |
| 165 | 83 | 152.3 | 230.1 |
| 170 | 76 | 154.2 | 238.7 |
| 175 | 72 | 153.3 | 240.1 |
| 180 | 63 | 147.1 | 230.3 |
| 185 | 49 | 146.9 | 220.0 |
