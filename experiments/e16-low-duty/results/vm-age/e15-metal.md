# VM memory against VM age -- E15 metal resident-inf, sealed ladder rungs N>=64

3315 VMs (3326 restores in worker.log) from 9 rungs; ages to 55 min (5-min bins). VM identity from worker.log restore/destroy events (fix round 1, I1).

growth_20_60_pct: **-** (0 VMs seen at both 20 and 60 min; needs 20).
SPEC §6 decision on these rungs: run the long rung (growth_20_60_pct is null: too few VMs observed at 60 min).
Informational (not the SPEC §6 metric): 20 to 50 min, 11.1% over 166 VMs seen at both.

| age (min) | VMs | median MiB | p95 MiB |
|---|---|---|---|
| 0 | 3315 | 54.7 | 142.1 |
| 5 | 1712 | 76.7 | 168.0 |
| 10 | 1300 | 91.9 | 179.9 |
| 15 | 1056 | 101.5 | 198.2 |
| 20 | 917 | 113.9 | 199.5 |
| 25 | 760 | 117.1 | 200.9 |
| 30 | 618 | 118.1 | 202.9 |
| 35 | 323 | 126.9 | 216.6 |
| 40 | 269 | 131.2 | 209.1 |
| 45 | 221 | 131.2 | 212.2 |
| 50 | 166 | 126.7 | 203.1 |
| 55 | 4 | 166.4 | 168.0 |

| rung | restores | VMs sampled | max age (min) | samples attributed | unattributed |
|---|---|---|---|---|---|
| e15/results/metal/default/resident-inf/N64 | 188 | 187 | 35 | 132807 | 17 |
| e15/results/metal/default/resident-inf/N80 | 262 | 260 | 35 | 165871 | 0 |
| e15/results/metal/default/resident-inf/N80-repeat | 312 | 311 | 50 | 261907 | 0 |
| e15/results/metal/default/resident-inf/N96 | 293 | 292 | 35 | 199231 | 1 |
| e15/results/metal/default/resident-inf/N96-repeat | 350 | 349 | 55 | 314119 | 20 |
| e15/results/metal/default/resident-inf/N128 | 392 | 391 | 35 | 265445 | 0 |
| e15/results/metal/default/resident-inf/N128-repeat | 475 | 474 | 55 | 418881 | 1 |
| e15/results/metal/default/resident-inf/N160 | 476 | 474 | 35 | 331875 | 28 |
| e15/results/metal/default/resident-inf/N160-repeat | 578 | 577 | 55 | 523832 | 124 |
