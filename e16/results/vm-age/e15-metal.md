# VM memory against VM age

8407 VMs from 18 rungs; ages to 55 min (5-min bins).

growth_20_60_pct: **-** (0 VMs seen at both 20 and 60 min; needs 20).
Informational: 20 to 55 min, 24.5% over 149 VMs.

| age (min) | VMs | median MiB | p95 MiB |
|---|---|---|---|
| 0 | 8407 | 56.8 | 141.0 |
| 5 | 6754 | 77.4 | 165.0 |
| 10 | 5454 | 88.9 | 177.9 |
| 15 | 4658 | 98.6 | 190.4 |
| 20 | 4066 | 109.6 | 193.8 |
| 25 | 3553 | 112.5 | 195.0 |
| 30 | 3031 | 116.5 | 194.7 |
| 35 | 1756 | 119.2 | 202.0 |
| 40 | 1405 | 124.2 | 200.4 |
| 45 | 1169 | 124.3 | 199.1 |
| 50 | 917 | 124.1 | 199.3 |
| 55 | 149 | 118.4 | 188.5 |

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
| e15/results/metal/default/resident-inf/supplementary-1s/N192-1s | 356 | 35 |
| e15/results/metal/default/resident-inf/supplementary-1s/N256-1s | 480 | 35 |
| e15/results/metal/default/resident-inf/supplementary-1s/N320-1s | 590 | 35 |
| e15/results/metal/default/resident-inf/supplementary-1s/N320-1s-repeat | 658 | 55 |
| e15/results/metal/default/resident-inf/supplementary-1s/N384-1s | 720 | 35 |
| e15/results/metal/default/resident-inf/supplementary-1s/N384-1s-repeat | 819 | 55 |
| e15/results/metal/default/resident-inf/supplementary-1s/N448-1s | 844 | 35 |
| e15/results/metal/default/resident-inf/supplementary-1s/N448-1s-repeat | 968 | 55 |
| e15/results/metal/default/resident-inf/supplementary-1s/N448-1s-repeat-g900 | 983 | 55 |
