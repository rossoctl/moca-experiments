# VM memory against VM age

1989 VMs from 9 rungs; ages to 55 min (5-min bins).

growth_20_60_pct: **-** (0 VMs seen at both 20 and 60 min; needs 20).
Informational: 20 to 50 min, 26.9% over 205 VMs.

| age (min) | VMs | median MiB | p95 MiB |
|---|---|---|---|
| 0 | 1989 | 56.5 | 137.8 |
| 5 | 1597 | 75.1 | 160.4 |
| 10 | 1281 | 90.6 | 174.6 |
| 15 | 1086 | 101.3 | 192.4 |
| 20 | 964 | 113.0 | 198.9 |
| 25 | 834 | 117.0 | 202.0 |
| 30 | 701 | 117.8 | 203.1 |
| 35 | 371 | 126.1 | 216.6 |
| 40 | 314 | 130.9 | 213.3 |
| 45 | 265 | 131.2 | 215.2 |
| 50 | 205 | 130.6 | 203.1 |
| 55 | 4 | 125.5 | 191.6 |

| rung | VMs | max age (min) |
|---|---|---|
| e15/results/metal/default/resident-inf/N64 | 120 | 35 |
| e15/results/metal/default/resident-inf/N80 | 154 | 35 |
| e15/results/metal/default/resident-inf/N80-repeat | 177 | 50 |
| e15/results/metal/default/resident-inf/N96 | 181 | 35 |
| e15/results/metal/default/resident-inf/N96-repeat | 207 | 55 |
| e15/results/metal/default/resident-inf/N128 | 236 | 35 |
| e15/results/metal/default/resident-inf/N128-repeat | 273 | 55 |
| e15/results/metal/default/resident-inf/N160 | 301 | 35 |
| e15/results/metal/default/resident-inf/N160-repeat | 340 | 55 |
