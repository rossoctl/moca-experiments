# E17 latency (SPEC §7.1)

Wall time (observed_ms) of in-window ok calls. Gain = 1 - (warm median / sbx median).

| point | N | arm | class | warm n | warm median ms | warm p95 ms | cold n | cold median ms | cold p95 ms | unknown | sbx median ms | gain |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| pycache | 1 | sbx | py_analyze | 0 | - | - | 12 | 15601 | 17873 | 0 | 15601 | - |
| pycache | 1 | sbx | py_grep | 0 | - | - | 5 | 1960 | 2009 | 0 | 1960 | - |
| pycache | 1 | sbx | py_import | 0 | - | - | 5 | 755 | 804 | 0 | 755 | - |
| pycache | 1 | sbx | py_short | 0 | - | - | 17 | 53 | 151 | 0 | 53 | - |
| pycache | 1 | sbx | py_test | 0 | - | - | 4 | 61232 | 61335 | 0 | 61232 | - |
| pycache | 1 | resident-300 | py_analyze | 11 | 14416 | 17782 | 1 | 17620 | 17620 | 0 | 15601 | 0.08 |
| pycache | 1 | resident-300 | py_grep | 5 | 2000 | 2208 | 0 | - | - | 0 | 1960 | -0.02 |
| pycache | 1 | resident-300 | py_import | 4 | 454 | 460 | 1 | 1902 | 1902 | 0 | 755 | 0.40 |
| pycache | 1 | resident-300 | py_short | 16 | 6 | 29 | 1 | 116 | 116 | 0 | 53 | 0.89 |
| pycache | 1 | resident-300 | py_test | 3 | 60977 | 61651 | 1 | 63230 | 63230 | 0 | 61232 | 0.00 |

## Warm share, first call after idle, call counts

| point | N | arm | warm share | first call after idle n | median ms | p95 ms | calls | used | unknown | not in window | not ok |
|---|---|---|---|---|---|---|---|---|---|---|---|
| pycache | 1 | sbx | 0.000 | 0 | - | - | 93 | 43 | 0 | 50 | 0 |
| pycache | 1 | resident-300 | 0.907 | 2 | 32566 | 63230 | 93 | 43 | 0 | 50 | 0 |
