# E15 metal run (m7i.metal-24xl): results against the sealed metal predictions

Host: AWS m7i.metal-24xl, bare metal, 96 vCPU (48 cores x 2 threads), 377 GiB, EBS gp3 XFS reflink at /srv/e15. Sealed predictions: `e15/predictions-metal.json` (3d653a2). Procedure as sealed: warm-up 1200 s, window 900 s, footprint drift on summed VM memory, SH_MAX_RUNS 2048, fresh-metal ladder to 1024. Calibration: `calibration-summary.md`.

## Ladders (sealed verdicts)

| point | arm | n_max | n_max_abs | first failed rung | why it failed | host CPU mean at that rung |
|---|---|---|---|---|---|---|
| default | sbx | 80 | 80 | 96 | added_latency (p95 excess 433 ms vs 345 ms; 0 failed calls; binding none) | 9.0% |
| default | resident-inf | 128 | 128 | 160 | added_latency (p95 excess 453 ms vs 379 ms; 0 failed calls; binding none) | 12.0% |
| default | resident-300 | 128 | 128 | 160 | added_latency (p95 excess 445 ms vs 371 ms; 0 failed calls; binding none) | 13.1% |
| mem512 | sbx | 8 | 8 | 16 | added_latency (p95 excess 1888 ms vs 753 ms; 0 failed calls; binding none) | 2.0% |
| mem512 | resident-inf | 8 | 8 | 16 | added_latency (p95 excess 462 ms vs 391 ms; 0 failed calls; binding none) | 1.8% |

- default resident-inf: ladder.json assembled after a rig error: sealed chain to N=56; its repeat hit unseeded sessions (rig error); re-run once with K doubled (the sealed unseeded rule) counts; resumed from the next rung (ladder.part2.json).
- default resident-300: ladder.json assembled after a rig error: sealed chain to N=96; its repeat hit unseeded sessions (rig error); re-run once with K doubled (the sealed unseeded rule) counts; resumed from the next rung (ladder.part2.json).

## Sealed predictions

| # | claim (sealed) | outcome | verdict |
|---|---|---|---|
| 1 | SBX is bound by CPU. Resident ∞ is bound by memory. | SBX's first failed rung (N=96): condition 4, binding none, host CPU ~9% (not memory, not CPU-saturated). Resident ∞'s (N=160): condition 4, binding none, host CPU ~12%, MemAvailable 356 GiB (not memory-bound) | **FALSIFIED**: neither arm was bound by the resource named; both failed on condition 4 tails of CPU-heavy calls far below any host wall |
| 2 | SBX holds more sessions than resident ∞ at the default point. Predicted ranges: SBX N_max in [384, 448]; resident ∞ N_max in [384, 448]. | n_max SBX 80, resident ∞ 128 (ranges: SBX in range False, resident in range False) | direction **FALSIFIED**; numeric **FALSIFIED** |
| 3 | Resident 300 s comes within one ladder step of SBX, in either direction. Predicted range: resident 300 s N_max in [384, 448]. | n_max resident 300 s 128 vs SBX 80 (ladder steps apart: 2) | **FALSIFIED** |
| 4 | Longer gaps help SBX and resident 300 s, not resident ∞. At H = 7200 s, SBX's and resident 300 s's N_max rise; resident ∞ stays within one ladder step of its default. | not run on metal (SPEC §13 metal procedure) | not tested |
| 5 | Removing host-infrastructure sessions and chains moves both arms the same way. Neither point reverses the default result. | not run on metal (SPEC §13 metal procedure) | not tested |
| 6 | The driver uses less than 1% of host CPU at every N (A2). | max a2_pct_of_host over 43 ladder rungs = 0.0229% | **HOLDS** |
| 7 | method, not a prediction | applied as sealed | n/a |
| 8 | The m7i.metal-24xl run shows the largest SBX gain: n_max(SBX) / n_max(resident ∞) at the default point on metal is larger than on the preliminary nested instance, where it was 1 (8 / 8, primary). | metal n_max(SBX)/n_max(resident ∞) = 80/128 = 0.625 vs preliminary 1.0 (abs: 80/128 vs 0.125) | **FALSIFIED** |
| 9 | At mem512, resident ∞ is bound by memory and SBX holds more sessions than resident ∞. Predicted ranges: resident ∞ N_max in [320, 320]; SBX N_max in [1, 1]. | n_max SBX 8, resident ∞ 8; resident ∞ first failed rung binding none (memory-bound: False) | **FALSIFIED** |

## Per-rung detail: relative slowdown (supplementary, not sealed)

Condition 4 is in absolute milliseconds. A call that runs for minutes fails it on a slowdown of a few percent: 3% of a 240 s pytest run is 7 s of excess. The table gives, per rung, the median and p95 of observed ÷ planned run time over window calls planned at ≥ 1 s, beside the p95 excess the sealed rule judges.

### default / sbx

| N | window calls | p95 excess (ms) | primary limit (ms) | calls ≥ 1 s | slowdown median | slowdown p95 | sealed holds / abs | holds_1s | holds_cpu |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 14 |  |  | 0 |  |  | true / true |  |  |
| 8 | 100 | 111 | 345 | 20 | 1.002 | 1.016 | true / true |  |  |
| 16 | 286 | 198 | 345 | 81 | 1.005 | 1.041 | true / true |  |  |
| 24 | 357 | 130 | 345 | 101 | 1.004 | 1.038 | true / true |  |  |
| 32 | 602 | 167 | 345 | 205 | 1.005 | 1.066 | true / true |  |  |
| 40 | 849 | 243 | 345 | 267 | 1.008 | 1.044 | true / true |  |  |
| 48 | 943 | 154 | 345 | 233 | 1.005 | 1.084 | true / true |  |  |
| 56 | 1116 | 203 | 345 | 341 | 1.008 | 1.101 | true / true |  |  |
| 64 | 1457 | 254 | 345 | 449 | 1.010 | 1.080 | true / true |  |  |
| 80 | 1868 | 270 | 345 | 501 | 1.012 | 1.121 | true / true |  |  |
| 96 | 1962 | 433 | 345 | 459 | 1.018 | 1.079 | false / false |  |  |

### default / resident-inf

| N | window calls | p95 excess (ms) | primary limit (ms) | calls ≥ 1 s | slowdown median | slowdown p95 | sealed holds / abs | holds_1s | holds_cpu |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 14 |  |  | 0 |  |  | true / true |  |  |
| 8 | 100 | 88 | 379 | 20 | 0.996 | 1.001 | true / true |  |  |
| 16 | 312 | 110 | 379 | 51 | 0.999 | 1.006 | true / true |  |  |
| 24 | 361 | 99 | 379 | 101 | 0.993 | 1.006 | true / true |  |  |
| 32 | 602 | 139 | 379 | 205 | 0.996 | 1.008 | true / true |  |  |
| 40 | 787 | 110 | 379 | 189 | 0.992 | 1.010 | true / true |  |  |
| 48 | 818 | 109 | 379 | 231 | 0.976 | 1.021 | true / true |  |  |
| 56 | 1209 | 94 | 379 | 314 | 0.988 | 1.016 | true / true |  |  |
| 64 | 1457 | 154 | 379 | 450 | 0.995 | 1.021 | true / true |  |  |
| 80 | 1579 | 162 | 379 | 362 | 0.997 | 1.023 | true / true |  |  |
| 96 | 1830 | 197 | 379 | 378 | 1.003 | 1.049 | true / true |  |  |
| 128 | 2449 | 183 | 379 | 491 | 1.007 | 1.046 | true / true |  |  |
| 160 | 3238 | 453 | 379 | 768 | 1.014 | 1.065 | false / false |  |  |

### default / resident-300

| N | window calls | p95 excess (ms) | primary limit (ms) | calls ≥ 1 s | slowdown median | slowdown p95 | sealed holds / abs | holds_1s | holds_cpu |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 14 |  |  | 0 |  |  | true / true |  |  |
| 8 | 112 | 85 | 371 | 47 | 0.999 | 1.005 | true / true |  |  |
| 16 | 286 | 180 | 371 | 81 | 0.999 | 1.010 | true / true |  |  |
| 24 | 361 | 110 | 371 | 101 | 0.997 | 1.007 | true / true |  |  |
| 32 | 602 | 136 | 371 | 205 | 0.997 | 1.009 | true / true |  |  |
| 40 | 849 | 144 | 371 | 267 | 0.998 | 1.020 | true / true |  |  |
| 48 | 945 | 121 | 371 | 233 | 0.992 | 1.024 | true / true |  |  |
| 56 | 1153 | 141 | 371 | 348 | 0.991 | 1.021 | true / true |  |  |
| 64 | 1457 | 144 | 371 | 450 | 0.995 | 1.020 | true / true |  |  |
| 80 | 1640 | 169 | 371 | 397 | 0.998 | 1.033 | true / true |  |  |
| 96 | 1853 | 156 | 371 | 374 | 1.000 | 1.029 | true / true |  |  |
| 128 | 2467 | 336 | 371 | 579 | 1.004 | 1.043 | true / true |  |  |
| 160 | 3238 | 445 | 371 | 772 | 1.009 | 1.065 | false / false |  |  |

### mem512 / sbx

| N | window calls | p95 excess (ms) | primary limit (ms) | calls ≥ 1 s | slowdown median | slowdown p95 | sealed holds / abs | holds_1s | holds_cpu |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 14 |  |  | 0 |  |  | true / true |  |  |
| 8 | 100 | 305 | 753 | 20 | 1.003 | 1.096 | true / true |  |  |
| 16 | 285 | 1888 | 753 | 81 | 1.011 | 1.134 | false / false |  |  |

### mem512 / resident-inf

| N | window calls | p95 excess (ms) | primary limit (ms) | calls ≥ 1 s | slowdown median | slowdown p95 | sealed holds / abs | holds_1s | holds_cpu |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 14 |  |  | 0 |  |  | true / true |  |  |
| 8 | 100 | 94 | 391 | 20 | 0.998 | 1.008 | true / true |  |  |
| 16 | 287 | 462 | 391 | 81 | 1.000 | 1.044 | false / false |  |  |

## Supplementary (not sealed): 1-second limit and CPU wall

User decisions 2026-11-04/05, recorded before the rungs they judge. Not part of the sealed procedure; predictions-metal.json is untouched. `holds_1s`: SPEC §8 conditions 1–3 unchanged, condition 4 = p95 excess ≤ 1000 ms (both verdicts). `holds_cpu`: conditions 1–3 only. Each default arm climbs from its sealed first-failed rung (re-judged, not re-run) up the metal ladder until a rung fails conditions 1–3; rungs run with the sealed procedure (tag 1s).

| arm | n_max (sealed) | n_max_1s | n_max_cpu | first rung failing 1–3 | its reason |
|---|---|---|---|---|---|
| sbx | 80 | (climb not finished) | | | |
| resident-inf | 128 | (climb not finished) | | | |
| resident-300 | 128 | (climb not finished) | | | |

