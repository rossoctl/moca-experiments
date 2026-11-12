# E17 latency (SPEC §7.1)

Wall time (observed_ms) of in-window ok calls. Gain = 1 - (warm median / sbx median).

| point | N | arm | class | warm n | warm median ms | warm p95 ms | cold n | cold median ms | cold p95 ms | unknown | sbx median ms | gain |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| pycache | 128 | sbx | py_analyze | 0 | - | - | 211 | 18489 | 21239 | 0 | 18489 | - |
| pycache | 128 | sbx | py_grep | 0 | - | - | 96 | 2013 | 2254 | 0 | 2013 | - |
| pycache | 128 | sbx | py_import | 0 | - | - | 90 | 900 | 2154 | 0 | 900 | - |
| pycache | 128 | sbx | py_short | 0 | - | - | 391 | 60 | 124 | 0 | 60 | - |
| pycache | 128 | sbx | py_test | 0 | - | - | 90 | 68642 | 72587 | 0 | 68642 | - |
| pycache | 128 | resident-300 | py_analyze | 183 | 16828 | 20133 | 29 | 19035 | 21226 | 0 | 18489 | 0.09 |
| pycache | 128 | resident-300 | py_grep | 89 | 1987 | 2323 | 8 | 2247 | 2299 | 0 | 2013 | 0.01 |
| pycache | 128 | resident-300 | py_import | 76 | 520 | 589 | 14 | 2048 | 2172 | 0 | 900 | 0.42 |
| pycache | 128 | resident-300 | py_short | 340 | 5 | 24 | 55 | 94 | 111 | 0 | 60 | 0.91 |
| pycache | 128 | resident-300 | py_test | 81 | 66950 | 70086 | 9 | 70401 | 72101 | 0 | 68642 | 0.02 |

## Warm share, first call after idle, call counts

| point | N | arm | warm share | first call after idle n | median ms | p95 ms | calls | used | unknown | not in window | not ok |
|---|---|---|---|---|---|---|---|---|---|---|---|
| pycache | 128 | sbx | 0.000 | 0 | - | - | 2345 | 878 | 0 | 1467 | 0 |
| pycache | 128 | resident-300 | 0.870 | 83 | 111 | 21424 | 2354 | 884 | 0 | 1470 | 0 |
