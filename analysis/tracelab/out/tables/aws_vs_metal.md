| point | arm | N | AWS holds | metal holds | AWS p95 excess ms | metal p95 excess ms | AWS limit ms | metal limit ms | AWS host CPU % | metal host CPU % | AWS window calls | metal window calls |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| default | resident-300 | 1 | True | True | None | None | None | None | 1.8 | 0.1 | 7 | 14 |
| default | resident-300 | 8 | True | True | 366.9 | 85.0 | 871.4 | 371.4 | 15.9 | 1.0 | 132 | 112 |
| default | resident-300 | 16 | False | True | 13052.9 | 179.8 | 871.4 | 371.4 | 54.5 | 1.8 | 283 | 286 |
| default | resident-inf | 1 | True | True | None | None | None | None | 1.8 | 0.1 | 7 | 14 |
| default | resident-inf | 8 | True | True | 359.2 | 88.3 | 852.8 | 378.5 | 15.8 | 0.4 | 132 | 100 |
| default | resident-inf | 16 | False | True | 15200.3 | 110.3 | 852.8 | 378.5 | 54.0 | 1.4 | 283 | 312 |
| default | sbx | 1 | True | True | None | None | None | None | 1.8 | 0.1 | 7 | 14 |
| default | sbx | 8 | True | True | 566.3 | 111.4 | 687.5 | 345.2 | 16.8 | 0.4 | 132 | 100 |
| default | sbx | 16 | False | True | 1544.7 | 198.0 | 687.5 | 345.2 | 40.7 | 1.9 | 439 | 286 |
| mem512 | resident-inf | 1 | True | True | None | None | None | None | 1.7 | 0.1 | 7 | 14 |
| mem512 | resident-inf | 8 | True | True | 557.2 | 94.3 | 861.6 | 390.7 | 16.2 | 0.4 | 132 | 100 |
| mem512 | resident-inf | 16 | False | False | 3413.3 | 461.5 | 861.6 | 390.7 | 42.7 | 1.8 | 426 | 287 |
| mem512 | sbx | 1 | True | True | None | None | None | None | 1.9 | 0.1 | 7 | 14 |
| mem512 | sbx | 8 | False | True | 1714.6 | 304.9 | 895.5 | 752.9 | 21.7 | 0.5 | 135 | 100 |
