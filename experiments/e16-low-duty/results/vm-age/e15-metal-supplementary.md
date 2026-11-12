# VM memory against VM age -- E15 metal resident-inf, supplementary-1s climb (not sealed)

10794 VMs (10824 restores in worker.log) from 9 rungs; ages to 55 min (5-min bins). VM identity from worker.log restore/destroy events (fix round 1, I1).

growth_20_60_pct: **-** (0 VMs seen at both 20 and 60 min; needs 20).
SPEC §6 decision on these rungs: run the long rung (growth_20_60_pct is null: too few VMs observed at 60 min).
Informational (not the SPEC §6 metric): 20 to 50 min, 18.0% over 564 VMs seen at both.
Informational (not the SPEC §6 metric): 20 to 55 min, 22.5% over 89 VMs seen at both.

| age (min) | VMs | median MiB | p95 MiB |
|---|---|---|---|
| 0 | 10794 | 56.2 | 149.1 |
| 5 | 5562 | 80.6 | 174.2 |
| 10 | 4145 | 90.7 | 181.6 |
| 15 | 3438 | 97.4 | 190.7 |
| 20 | 2942 | 108.9 | 192.9 |
| 25 | 2502 | 111.3 | 193.6 |
| 30 | 2085 | 115.4 | 192.3 |
| 35 | 1198 | 118.4 | 195.6 |
| 40 | 954 | 121.1 | 194.7 |
| 45 | 750 | 119.8 | 195.8 |
| 50 | 564 | 121.5 | 196.2 |
| 55 | 89 | 119.4 | 188.5 |

| rung | restores | VMs sampled | max age (min) | samples attributed | unattributed |
|---|---|---|---|---|---|
| e15/results/metal/default/resident-inf/supplementary-1s/N192-1s | 578 | 577 | 35 | 398147 | 111 |
| e15/results/metal/default/resident-inf/supplementary-1s/N256-1s | 804 | 801 | 35 | 531255 | 183 |
| e15/results/metal/default/resident-inf/supplementary-1s/N320-1s | 958 | 955 | 35 | 663675 | 140 |
| e15/results/metal/default/resident-inf/supplementary-1s/N320-1s-repeat | 1157 | 1154 | 55 | 1048098 | 57 |
| e15/results/metal/default/resident-inf/supplementary-1s/N384-1s | 1166 | 1163 | 35 | 802573 | 1509 |
| e15/results/metal/default/resident-inf/supplementary-1s/N384-1s-repeat | 1378 | 1374 | 55 | 1263009 | 1566 |
| e15/results/metal/default/resident-inf/supplementary-1s/N448-1s | 1361 | 1357 | 35 | 905079 | 1959 |
| e15/results/metal/default/resident-inf/supplementary-1s/N448-1s-repeat | 1700 | 1695 | 55 | 1438598 | 2466 |
| e15/results/metal/default/resident-inf/supplementary-1s/N448-1s-repeat-g900 | 1722 | 1718 | 55 | 1463142 | 2381 |
