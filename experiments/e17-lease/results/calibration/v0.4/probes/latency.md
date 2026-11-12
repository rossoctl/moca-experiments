# E17 latency (SPEC §7.1)

Wall time (observed_ms) of in-window ok calls. Gain = 1 - (warm median / sbx median).

| point | N | arm | class | warm n | warm median ms | warm p95 ms | cold n | cold median ms | cold p95 ms | unknown | sbx median ms | gain |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| pycache | 1 | sbx | py_analyze | 0 | - | - | 20 | 15345 | 16775 | 0 | 15345 | - |
| pycache | 1 | sbx | py_grep | 0 | - | - | 20 | 388 | 401 | 0 | 388 | - |
| pycache | 1 | sbx | py_import | 0 | - | - | 20 | 755 | 766 | 0 | 755 | - |
| pycache | 1 | sbx | py_short | 0 | - | - | 20 | 47 | 79 | 0 | 47 | - |
| pycache | 1 | sbx | py_test | 0 | - | - | 20 | 61377 | 61881 | 0 | 61377 | - |
| pycache | 1 | resident-300 | py_analyze | 19 | 14568 | 14842 | 1 | 17852 | 17852 | 0 | 15345 | 0.05 |
| pycache | 1 | resident-300 | py_grep | 19 | 112 | 115 | 1 | 2210 | 2210 | 0 | 388 | 0.71 |
| pycache | 1 | resident-300 | py_import | 19 | 453 | 454 | 1 | 1952 | 1952 | 0 | 755 | 0.40 |
| pycache | 1 | resident-300 | py_short | 19 | 5 | 36 | 1 | 95 | 95 | 0 | 47 | 0.90 |
| pycache | 1 | resident-300 | py_test | 19 | 60811 | 61127 | 1 | 62654 | 62654 | 0 | 61377 | 0.01 |

## Warm share, first call after idle, call counts

| point | N | arm | warm share | first call after idle n | median ms | p95 ms | calls | used | unknown | not in window | not ok |
|---|---|---|---|---|---|---|---|---|---|---|---|
| pycache | 1 | sbx | 0.000 | 0 | - | - | 100 | 100 | 0 | 0 | 0 |
| pycache | 1 | resident-300 | 0.950 | 0 | - | - | 100 | 100 | 0 | 0 | 0 |
