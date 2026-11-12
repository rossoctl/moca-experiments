| experiment | arm | N | counted run | holds | failed calls | latency: p95 excess % of limit | host CPU mean % | host CPU p95 % | CPU PSI max | memory used % (1 − MemAvailable min) | disk read p95 % of max | admission at 1,056 MiB/VM % of RAM | peak concurrent Execs | Execs % of 320 | live VMs max | long calls (≥ 30 s) | long slowdown p50 | long slowdown p95 | source |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| E15 metal default | sbx | 8 | N8 | True | 0 | 32.3 | 0.4 | 1.4 | 0.0 | 1.7 | 0.3 | 2.7 | 3 | 0.9 | 10 | 11 | 1.001 | 1.004 | final @7a90a76 |
| E15 metal default | sbx | 16 | N16 | True | 0 | 57.4 | 1.9 | 3.9 | 0.0 | 1.7 | 0.6 | 6.0 | 6 | 1.9 | 22 | 25 | 1.004 | 1.009 | final @7a90a76 |
| E15 metal default | sbx | 24 | N24 | True | 0 | 37.6 | 2.8 | 5.3 | 0.0 | 1.8 | 0.6 | 9.0 | 7 | 2.2 | 33 | 29 | 1.003 | 1.008 | final @7a90a76 |
| E15 metal default | sbx | 32 | N32 | True | 0 | 48.4 | 4.4 | 6.5 | 0.0 | 1.8 | 0.9 | 13.7 | 11 | 3.4 | 50 | 43 | 1.004 | 1.035 | final @7a90a76 |
| E15 metal default | sbx | 40 | N40 | True | 0 | 70.3 | 4.8 | 8.6 | 0.0 | 1.9 | 1.2 | 16.4 | 14 | 4.4 | 60 | 72 | 1.005 | 1.017 | final @7a90a76 |
| E15 metal default | sbx | 48 | N48 | True | 0 | 44.7 | 3.3 | 5.5 | 0.0 | 1.8 | 1.2 | 13.7 | 9 | 2.8 | 50 | 46 | 1.004 | 1.013 | final @7a90a76 |
| E15 metal default | sbx | 56 | N56 | True | 0 | 58.9 | 4.3 | 7.2 | 0.0 | 1.8 | 1.4 | 17.8 | 12 | 3.8 | 65 | 63 | 1.004 | 1.016 | final @7a90a76 |
| E15 metal default | sbx | 64 | N64 | True | 0 | 73.6 | 5.7 | 8.6 | 0.0 | 1.9 | 1.7 | 21.6 | 15 | 4.7 | 79 | 79 | 1.008 | 1.017 | final @7a90a76 |
| E15 metal default | sbx | 80 | N80 | True | 0 | 78.1 | 7.3 | 11.9 | 0.0 | 2.0 | 2.0 | 28.7 | 17 | 5.3 | 105 | 98 | 1.009 | 1.03 | final @7a90a76 |
| E15 metal default | sbx | 96 | N96 | False | 0 | 125.4 | 9.0 | 12.6 | 0.0 | 2.0 | 2.0 | 29.0 | 19 | 5.9 | 106 | 103 | 1.016 | 1.035 | final @7a90a76 |
| E15 metal default | resident-inf | 8 | N8 | True | 0 | 23.3 | 0.4 | 1.2 | 0.0 | 1.8 | 0.0 | 2.2 | 3 | 0.9 | 8 | 11 | 0.999 | 0.999 | final @7a90a76 |
| E15 metal default | resident-inf | 16 | N16-repeat | True | 0 | 29.1 | 1.4 | 3.3 | 0.0 | 2.1 | 0.0 | 4.4 | 5 | 1.6 | 16 | 18 | 0.999 | 1.006 | final @7a90a76 |
| E15 metal default | resident-inf | 24 | N24 | True | 0 | 26.2 | 2.8 | 5.3 | 0.0 | 2.2 | 0.0 | 6.6 | 7 | 2.2 | 24 | 29 | 0.999 | 1.004 | final @7a90a76 |
| E15 metal default | resident-inf | 32 | N32 | True | 0 | 36.7 | 4.4 | 6.4 | 0.0 | 2.4 | 0.0 | 8.7 | 10 | 3.1 | 32 | 43 | 1.0 | 1.007 | final @7a90a76 |
| E15 metal default | resident-inf | 40 | N40-repeat | True | 0 | 29.1 | 3.1 | 5.4 | 0.0 | 2.7 | 0.1 | 10.9 | 9 | 2.8 | 40 | 31 | 1.001 | 1.01 | final @7a90a76 |
| E15 metal default | resident-inf | 48 | N48-repeat | True | 0 | 28.9 | 2.8 | 5.6 | 0.0 | 2.8 | 0.0 | 13.1 | 9 | 2.8 | 48 | 38 | 0.997 | 1.005 | final @7a90a76 |
| E15 metal default | resident-inf | 56 | N56-repeat-k2 | True | 0 | 24.7 | 3.4 | 6.2 | 0.0 | 3.1 | 0.1 | 15.3 | 9 | 2.8 | 56 | 50 | 1.0 | 1.008 | final @7a90a76 |
| E15 metal default | resident-inf | 64 | N64 | True | 0 | 40.7 | 5.5 | 8.2 | 0.0 | 3.1 | 0.3 | 17.5 | 15 | 4.7 | 64 | 79 | 1.001 | 1.011 | final @7a90a76 |
| E15 metal default | resident-inf | 80 | N80-repeat | True | 0 | 42.8 | 5.7 | 9.0 | 0.0 | 3.7 | 0.3 | 21.9 | 13 | 4.1 | 80 | 73 | 1.004 | 1.015 | final @7a90a76 |
| E15 metal default | resident-inf | 96 | N96-repeat | True | 0 | 52.0 | 6.5 | 10.5 | 0.0 | 4.1 | 0.3 | 26.2 | 17 | 5.3 | 96 | 83 | 1.008 | 1.025 | final @7a90a76 |
| E15 metal default | resident-inf | 128 | N128-repeat | True | 0 | 48.4 | 6.9 | 11.2 | 0.0 | 4.7 | 0.4 | 35.0 | 18 | 5.6 | 128 | 79 | 1.013 | 1.034 | final @7a90a76 |
| E15 metal default | resident-inf | 160 | N160-repeat | False | 0 | 119.6 | 12.0 | 17.2 | 0.0 | 5.5 | 0.4 | 43.7 | 29 | 9.1 | 160 | 146 | 1.019 | 1.05 | final @7a90a76 |
| E15 metal default | resident-300 | 8 | N8-repeat | True | 0 | 22.9 | 1.0 | 2.2 | 0.0 | 1.8 | 0.0 | 1.6 | 4 | 1.2 | 6 | 13 | 0.999 | 1.001 | final @7a90a76 |
| E15 metal default | resident-300 | 16 | N16 | True | 0 | 48.4 | 1.8 | 3.9 | 0.0 | 1.9 | 0.0 | 3.6 | 6 | 1.9 | 13 | 25 | 0.999 | 1.004 | final @7a90a76 |
| E15 metal default | resident-300 | 24 | N24 | True | 0 | 29.7 | 2.7 | 5.3 | 0.0 | 2.1 | 0.0 | 5.2 | 8 | 2.5 | 19 | 29 | 0.999 | 1.004 | final @7a90a76 |
| E15 metal default | resident-300 | 32 | N32 | True | 0 | 36.6 | 4.4 | 6.3 | 0.0 | 2.2 | 0.1 | 6.3 | 10 | 3.1 | 23 | 43 | 1.0 | 1.005 | final @7a90a76 |
| E15 metal default | resident-300 | 40 | N40 | True | 0 | 38.9 | 4.7 | 8.4 | 0.0 | 2.4 | 0.3 | 8.7 | 13 | 4.1 | 32 | 72 | 1.0 | 1.009 | final @7a90a76 |
| E15 metal default | resident-300 | 48 | N48 | True | 0 | 32.5 | 3.2 | 5.4 | 0.0 | 2.4 | 0.3 | 9.3 | 8 | 2.5 | 34 | 46 | 1.0 | 1.007 | final @7a90a76 |
| E15 metal default | resident-300 | 56 | N56 | True | 0 | 37.9 | 4.2 | 6.9 | 0.0 | 2.6 | 0.3 | 11.2 | 13 | 4.1 | 41 | 63 | 1.0 | 1.006 | final @7a90a76 |
| E15 metal default | resident-300 | 64 | N64 | True | 0 | 38.8 | 5.5 | 8.2 | 0.0 | 2.6 | 0.3 | 11.5 | 15 | 4.7 | 42 | 79 | 1.001 | 1.007 | final @7a90a76 |
| E15 metal default | resident-300 | 80 | N80 | True | 0 | 45.4 | 7.1 | 11.4 | 0.0 | 2.9 | 0.3 | 15.3 | 16 | 5.0 | 56 | 92 | 1.002 | 1.012 | final @7a90a76 |
| E15 metal default | resident-300 | 96 | N96-repeat-k2 | True | 0 | 41.9 | 5.7 | 9.4 | 0.0 | 3.0 | 0.3 | 16.7 | 17 | 5.3 | 61 | 73 | 1.004 | 1.015 | final @7a90a76 |
| E15 metal default | resident-300 | 128 | N128 | True | 0 | 90.3 | 10.3 | 14.4 | 0.0 | 3.5 | 0.4 | 24.0 | 23 | 7.2 | 88 | 146 | 1.011 | 1.03 | final @7a90a76 |
| E15 metal default | resident-300 | 160 | N160 | False | 0 | 119.9 | 13.1 | 19.3 | 0.0 | 3.9 | 0.4 | 28.7 | 28 | 8.8 | 105 | 156 | 1.021 | 1.05 | final @7a90a76 |
| E15 metal mem512 | sbx | 8 | N8 | True | 0 | 40.5 | 0.5 | 1.7 | 0.0 | 2.1 | 0.6 | 2.7 | 3 | 0.9 | 10 | 11 | 1.001 | 1.004 | final @7a90a76 |
| E15 metal mem512 | sbx | 16 | N16 | False | 0 | 250.7 | 2.0 | 4.3 | 0.0 | 2.7 | 16.1 | 6.0 | 6 | 1.9 | 22 | 25 | 1.004 | 1.035 | final @7a90a76 |
| E15 metal mem512 | resident-inf | 8 | N8 | True | 0 | 24.1 | 0.4 | 1.3 | 0.0 | 2.9 | 0.0 | 2.2 | 3 | 0.9 | 8 | 11 | 0.998 | 1.0 | final @7a90a76 |
| E15 metal mem512 | resident-inf | 16 | N16 | False | 0 | 118.1 | 1.8 | 4.2 | 0.0 | 4.3 | 0.0 | 4.4 | 6 | 1.9 | 16 | 25 | 0.999 | 1.007 | final @7a90a76 |
| E16 lowduty | sbx | 256 | N256 | True | 0 | 37.4 | 3.4 | 6.0 | 0.0 | 2.2 | 3.1 | 49.7 | 12 | 3.8 | 182 | 18 | 1.036 | 1.055 | final @c8dba13 |
| E16 lowduty | sbx | 384 | N384 | True | 0 | 44.6 | 5.6 | 9.7 | 0.0 | 2.4 | 4.3 | 76.8 | 16 | 5.0 | 281 | 62 | 1.033 | 1.084 | final @c8dba13 |
| E16 lowduty | sbx | 512 | N512 | True | 0 | 39.8 | 6.2 | 10.0 | 0.0 | 2.5 | 5.0 | 103.8 | 21 | 6.6 | 380 | 66 | 1.001 | 1.072 | final @c8dba13 |
| E16 lowduty | sbx | 640 | N640 | True | 0 | 50.7 | 8.2 | 12.7 | 0.0 | 2.6 | 5.6 | 120.5 | 21 | 6.6 | 441 | 103 | 1.0 | 1.086 | final @c8dba13 |
| E16 lowduty | sbx | 768 | N768 | True | 0 | 49.5 | 9.6 | 14.5 | 0.0 | 2.7 | 7.3 | 142.9 | 22 | 6.9 | 523 | 109 | 1.001 | 1.107 | final @c8dba13 |
| E16 lowduty | sbx | 896 | N896 | True | 0 | 62.6 | 12.0 | 18.0 | 0.0 | 2.9 | 8.2 | 181.1 | 28 | 8.8 | 663 | 130 | 1.017 | 1.138 | final @c8dba13 |
| E16 lowduty | sbx | 1024 | N1024 | True | 0 | 64.4 | 13.8 | 19.2 | 0.0 | 3.0 | 9.2 | 189.3 | 34 | 10.6 | 693 | 156 | 1.001 | 1.145 | final @c8dba13 |
| E16 lowduty | sbx | 1280 | N1280 | True | 0 | 78.4 | 17.9 | 27.8 | 0.0 | 3.2 | 11.3 | 253.0 | 49 | 15.3 | 926 | 180 | 1.001 | 1.197 | final @c8dba13 |
| E16 lowduty | sbx | 1536 | N1536 | True | 0 | 86.3 | 21.7 | 28.3 | 0.0 | 3.3 | 12.5 | 282.5 | 46 | 14.4 | 1034 | 261 | 1.001 | 1.192 | final @c8dba13 |
| E16 lowduty | resident-inf | 256 | N256 | True | 0 | 25.5 | 2.8 | 5.2 | 0.0 | 7.3 | 0.4 | 69.9 | 10 | 3.1 | 256 | 35 | 0.998 | 1.031 | final @c8dba13 |
| E16 lowduty | resident-inf | 384 | N384 | True | 0 | 33.3 | 5.2 | 8.9 | 0.0 | 9.9 | 0.4 | 104.9 | 16 | 5.0 | 384 | 76 | 0.998 | 1.063 | final @c8dba13 |
| E16 lowduty | resident-inf | 512 | N512-repeat | True | 0 | 43.9 | 6.4 | 10.5 | 0.0 | 13.9 | 0.5 | 139.9 | 16 | 5.0 | 512 | 71 | 0.998 | 1.097 | final @c8dba13 |
| E16 lowduty | resident-inf | 640 | N640-repeat | True | 0 | 47.4 | 9.0 | 14.2 | 0.18 | 16.7 | 0.6 | 174.8 | 22 | 6.9 | 640 | 131 | 0.998 | 1.136 | final @c8dba13 |
| E16 lowduty | resident-inf | 768 | N768 | True | 0 | 40.1 | 8.5 | 13.8 | 0.18 | 18.1 | 0.5 | 209.8 | 23 | 7.2 | 768 | 90 | 1.003 | 1.118 | final @c8dba13 |
| E16 lowduty | resident-inf | 896 | N896 | True | 0 | 51.3 | 11.2 | 19.0 | 0.0 | 21.1 | 0.7 | 244.8 | 28 | 8.8 | 896 | 132 | 0.998 | 1.144 | final @c8dba13 |
| E16 lowduty | resident-inf | 1024 | N1024-s2 | True | 0 | 54.0 | 13.2 | 20.0 | 1.63 | 23.8 | 0.7 | 279.8 | 30 | 9.4 | 1024 | 155 | 0.998 | 1.166 | final @c8dba13 |
| E16 lowduty | resident-inf | 1280 | N1280 | False | 24 | 62.9 | 15.9 | 23.6 | 0.0 | 28.9 | 0.7 | 349.7 | 34 | 10.6 | 1280 | 145 | 1.001 | 1.188 | final @c8dba13 |
