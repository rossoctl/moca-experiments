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

Notes. Prediction 8 is stated on the primary verdict: metal 0.625 is not above the preliminary 1.0. On the absolute verdict the metal ratio n_max_abs(SBX)/n_max_abs(resident ∞) = 80/128 = 0.625 is above the preliminary 1/8 = 0.125, because the preliminary SBX n_max_abs was 1 (nested lifecycle overhead against B + 250); that is information, not the sealed claim. Prediction 9's SBX range [1, 1] is also missed (SBX held N=8): the calibration rung's 600 s warm-up drew a window with 8 cold first scans in 132 calls, the ladder's 1200 s warm-up 3 in 100. Both mem512 arms fail N=16 on the same cold-first-scan tail (a new session's scan #1 reads its own fresh 512 MiB data.bin from EBS); neither is memory-bound (resident VMs at the 1024 MiB cap, MemAvailable 370 GiB, e15.slice memory.events high 0).

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

User decisions 2026-11-04/05/06, recorded before the rungs they judge. They are not part of the sealed procedure, and predictions-metal.json is untouched. `holds_1s` keeps SPEC §8 conditions 1–3 and replaces condition 4 with p95 excess ≤ 1000 ms (both verdicts). `holds_cpu` is conditions 1–3 only (no failed call, no refusal, median class pace ≤ 10%). Each default arm climbs from its sealed first-failed rung (re-judged, not re-run) up the metal ladder until a rung fails conditions 1–3. New rungs use the sealed rung procedure (tag `1s`, warm-up 1200 s, sum-drift repeat at 2400 s with K doubled).

Grace-end artefact rule (ruling 2026-11-06): a climb rung whose only condition-1 failures are calls cancelled at the grace deadline is re-run once with a 900 s grace (tag `-g900`); the re-run counts, and both records are kept. This touches no sealed verdict. Every sealed first failure (all seven ladders) had 0 failed calls and failed condition 4 only.

| arm | n_max (sealed) | n_max_1s | first rung failing 1 s | n_max_cpu | first rung failing conditions 1–3 and why | p95-tail classes at the 1 s failure |
|---|---|---|---|---|---|---|
| sbx | 80 | 192 | 256 | 320 | N=384 (-g900 re-run; the first run was a grace-end artefact): one interpreter call planned 1,416 s ran 1,536 s (+8.5%) and hit the driver's per-call timeout (planned + 120 s); class pace +0.13%, host CPU 34%, PSI 0 | interpreter 81, opaque 46, build 25, write 17, test 16 |
| resident-inf | 128 | 192 | 256 | 384 | N=448 (-g900 re-run of the drift repeat; the repeat was a grace-end artefact): one interpreter call planned 1,064 s ran 1,185 s (+11%) and hit its timeout; class pace +0.10%, host CPU 40%, PSI 0 | interpreter 82, opaque 61, build 31, write 22, other 17 |
| resident-300 | 128 | 192 | 256 | 448 | N=512: one interpreter call planned 371 s ran 492 s (+33%) and hit its timeout; class pace +0.25%, host CPU mean 54% (p95 84%), CPU PSI 0.3 (the first CPU pressure of the run) | interpreter 82, opaque 52, build 26, write 19, test 18 |

### SBX vs resident: relative slowdown and host counters by rung

Long calls are calls planned at 30 s or more. Slowdown is observed ÷ planned run time. The perf columns are 60 s `perf stat -a` samples every 300 s in each climb rung's window (climb rungs only). aperf/mperf is about 1.58 on the idle host, the turbo ratio.

| N | arm | calls ≥ 1 s | slowdown median | p95 | calls ≥ 30 s | long median | long p95 | host CPU % | IPC | LLC miss | aperf/mperf | DRAM read MiB/s |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | sbx | 0 |  |  | 0 |  |  | 0.1 |  |  |  |  |
| 1 | resident-inf | 0 |  |  | 0 |  |  | 0.1 |  |  |  |  |
| 1 | resident-300 | 0 |  |  | 0 |  |  | 0.1 |  |  |  |  |
| 8 | sbx | 20 | 1.002 | 1.016 | 11 | 1.001 | 1.004 | 0.4 |  |  |  |  |
| 8 | resident-inf | 20 | 0.996 | 1.001 | 11 | 0.999 | 0.999 | 0.4 |  |  |  |  |
| 8 | resident-300 | 47 | 0.999 | 1.005 | 13 | 0.999 | 1.001 | 1.0 |  |  |  |  |
| 16 | sbx | 81 | 1.005 | 1.041 | 25 | 1.004 | 1.009 | 1.9 |  |  |  |  |
| 16 | resident-inf | 51 | 0.999 | 1.006 | 18 | 0.999 | 1.006 | 1.4 |  |  |  |  |
| 16 | resident-300 | 81 | 0.999 | 1.010 | 25 | 0.999 | 1.004 | 1.8 |  |  |  |  |
| 24 | sbx | 101 | 1.004 | 1.038 | 29 | 1.003 | 1.008 | 2.8 |  |  |  |  |
| 24 | resident-inf | 101 | 0.993 | 1.006 | 29 | 0.999 | 1.004 | 2.8 |  |  |  |  |
| 24 | resident-300 | 101 | 0.997 | 1.007 | 29 | 0.999 | 1.004 | 2.7 |  |  |  |  |
| 32 | sbx | 205 | 1.005 | 1.066 | 43 | 1.004 | 1.035 | 4.4 |  |  |  |  |
| 32 | resident-inf | 205 | 0.996 | 1.008 | 43 | 1.000 | 1.007 | 4.4 |  |  |  |  |
| 32 | resident-300 | 205 | 0.997 | 1.009 | 43 | 1.000 | 1.005 | 4.4 |  |  |  |  |
| 40 | sbx | 267 | 1.008 | 1.044 | 72 | 1.005 | 1.017 | 4.8 |  |  |  |  |
| 40 | resident-inf | 189 | 0.992 | 1.010 | 31 | 1.001 | 1.010 | 3.1 |  |  |  |  |
| 40 | resident-300 | 267 | 0.998 | 1.020 | 72 | 1.000 | 1.009 | 4.7 |  |  |  |  |
| 48 | sbx | 233 | 1.005 | 1.084 | 46 | 1.004 | 1.013 | 3.3 |  |  |  |  |
| 48 | resident-inf | 231 | 0.976 | 1.021 | 38 | 0.997 | 1.005 | 2.8 |  |  |  |  |
| 48 | resident-300 | 233 | 0.992 | 1.024 | 46 | 1.000 | 1.007 | 3.2 |  |  |  |  |
| 56 | sbx | 341 | 1.008 | 1.101 | 63 | 1.004 | 1.016 | 4.3 |  |  |  |  |
| 56 | resident-inf | 314 | 0.988 | 1.016 | 50 | 1.000 | 1.008 | 3.4 |  |  |  |  |
| 56 | resident-300 | 348 | 0.991 | 1.021 | 63 | 1.000 | 1.006 | 4.2 |  |  |  |  |
| 64 | sbx | 449 | 1.010 | 1.080 | 79 | 1.008 | 1.017 | 5.7 |  |  |  |  |
| 64 | resident-inf | 450 | 0.995 | 1.021 | 79 | 1.001 | 1.011 | 5.5 |  |  |  |  |
| 64 | resident-300 | 450 | 0.995 | 1.020 | 79 | 1.001 | 1.007 | 5.5 |  |  |  |  |
| 80 | sbx | 501 | 1.012 | 1.121 | 98 | 1.009 | 1.030 | 7.3 |  |  |  |  |
| 80 | resident-inf | 362 | 0.997 | 1.023 | 73 | 1.004 | 1.015 | 5.7 |  |  |  |  |
| 80 | resident-300 | 397 | 0.998 | 1.033 | 92 | 1.002 | 1.012 | 7.1 |  |  |  |  |
| 96 | sbx | 459 | 1.018 | 1.079 | 103 | 1.016 | 1.035 | 9.0 |  |  |  |  |
| 96 | resident-inf | 378 | 1.003 | 1.049 | 83 | 1.008 | 1.025 | 6.5 |  |  |  |  |
| 96 | resident-300 | 374 | 1.000 | 1.029 | 73 | 1.004 | 1.015 | 5.7 |  |  |  |  |
| 128 | sbx | 618 | 1.029 | 1.128 | 141 | 1.026 | 1.053 | 11.0 | 4.39 | 0.077 | 1.518 | 564 |
| 128 | resident-inf | 491 | 1.007 | 1.046 | 79 | 1.013 | 1.034 | 6.9 |  |  |  |  |
| 128 | resident-300 | 579 | 1.004 | 1.043 | 146 | 1.011 | 1.030 | 10.3 |  |  |  |  |
| 160 | sbx | 733 | 1.047 | 1.158 | 163 | 1.047 | 1.086 | 15.6 | 4.41 | 0.079 | 1.475 | 813 |
| 160 | resident-inf | 768 | 1.014 | 1.065 | 146 | 1.019 | 1.050 | 12.0 |  |  |  |  |
| 160 | resident-300 | 772 | 1.009 | 1.065 | 156 | 1.021 | 1.050 | 13.1 |  |  |  |  |
| 192 | sbx | 937 | 1.056 | 1.181 | 190 | 1.063 | 1.102 | 17.0 | 4.36 | 0.087 | 1.456 | 1059 |
| 192 | resident-inf | 922 | 1.022 | 1.092 | 202 | 1.030 | 1.075 | 15.7 | 4.47 | 0.040 | 1.490 | 665 |
| 192 | resident-300 | 872 | 1.019 | 1.086 | 186 | 1.026 | 1.063 | 15.0 | 4.47 | 0.048 | 1.512 | 644 |
| 256 | sbx | 1394 | 1.072 | 1.232 | 290 | 1.083 | 1.168 | 25.4 | 4.33 | 0.096 | 1.390 | 1435 |
| 256 | resident-inf | 1484 | 1.052 | 1.160 | 287 | 1.073 | 1.141 | 25.0 | 4.44 | 0.061 | 1.420 | 1039 |
| 256 | resident-300 | 1360 | 1.062 | 1.162 | 311 | 1.070 | 1.148 | 25.2 | 4.35 | 0.047 | 1.398 | 1056 |
| 320 | sbx | 1613 | 1.093 | 1.249 | 338 | 1.103 | 1.193 | 29.9 | 4.23 | 0.099 | 1.363 | 1815 |
| 320 | resident-inf | 1449 | 1.077 | 1.177 | 302 | 1.091 | 1.157 | 25.9 | 4.39 | 0.060 | 1.414 | 1025 |
| 320 | resident-300 | 1690 | 1.065 | 1.195 | 349 | 1.095 | 1.184 | 31.7 | 4.32 | 0.039 | 1.366 | 1094 |
| 384 | sbx | 1939 | 1.121 | 1.301 | 386 | 1.102 | 1.208 | 34.4 | 4.14 | 0.101 | 1.342 | 2183 |
| 384 | resident-inf | 1967 | 1.079 | 1.200 | 364 | 1.084 | 1.178 | 27.9 | 3.89 | 0.056 | 1.369 | 1728 |
| 384 | resident-300 | 1943 | 1.060 | 1.208 | 374 | 1.075 | 1.185 | 30.6 | 4.32 | 0.045 | 1.374 | 1255 |
| 448 | resident-inf | 2336 | 1.103 | 1.284 | 459 | 1.101 | 1.238 | 40.4 | 4.15 | 0.046 | 1.337 | 1690 |
| 448 | resident-300 | 2248 | 1.095 | 1.292 | 474 | 1.091 | 1.244 | 41.9 | 4.34 | 0.058 | 1.337 | 1550 |
| 512 | resident-300 | 2771 | 1.132 | 1.856 | 545 | 1.109 | 1.747 | 54.1 | 3.54 | 0.065 | 1.333 | 2648 |

Reading. (1) Every sealed first failure happened far below any host resource wall. Host CPU was 9–13% at the default point and 2% at mem512, CPU PSI 0, MemAvailable ≥ 356 GiB. perf was sampled only on climb rungs; at the nearest ones (SBX N=128/160, resident N=192) IPC was ≥ 4.3, LLC miss < 10% and turbo 1.48–1.52× base. Each failed condition 4 on a p95 tail of CPU-heavy calls (interpreter, test, opaque, build): minutes-long calls running 2–5% slow. Condition 4 is in absolute milliseconds, so a few-percent slowdown on a 4–25 minute call is several seconds of excess. (2) At equal N and equal host CPU (for example N=32, 4.4% in all three arms) SBX's long calls run slower than resident's: long-call median 1.004 vs 1.000 at N=32, 1.016 vs 1.008/1.004 at N=96, 1.047 vs 1.019/1.021 at N=160. The gap widens with N while the host counters stay unsaturated. This fits per-VM cold state (each SBX command starts in a fresh guest with a cold page cache and cold CPU caches), not host contention. That is why SBX's sealed n_max (80) is below resident's (128). (3) Without condition 4, both arms climb far higher. n_max_cpu is SBX 320, resident ∞ 384, resident 300 s 448. Each stops on one long interpreter call stretched 8–33% past its per-call timeout (planned + 120 s), with class pace still ≤ 0.25%. Turbo falls with load (1.58 idle → 1.33 at N=448–512) and DRAM read rises to 1.5–2.6 GB/s, so frequency loss explains part of every arm's slowdown at high N. CPU PSI first appears at resident 300 s N=512 (0.3; host CPU p95 84%). (4) The 1 s limit gives n_max_1s = 192 for all three arms.

