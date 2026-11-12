| scope | provider | turns with a shell call | shell calls | calls per turn | calls in turns with >= 2 % | turns with >= 2 % | max per turn | same-turn overlap % of pairs | same-turn pairs |
|---|---|---|---|---|---|---|---|---|---|
| all | claude | 147767 | 158610 | 1.07 | 12.4 | 6.0 | 20 | 34.2 | 10797 |
| all | codex | 148701 | 264670 | 1.78 | 66.0 | 39.5 | 21 | 97.7 | 115960 |
| all | all | 296468 | 423280 | 1.43 | 45.9 | 22.8 |  |  |  |
| dedup | claude | 144834 | 155520 | 1.07 | 12.5 | 6.0 | 20 | 33.7 | 10654 |
| dedup | codex | 147161 | 261482 | 1.78 | 65.8 | 39.3 | 21 | 99.0 | 114312 |
| dedup | all | 291995 | 417002 | 1.43 | 45.9 | 22.8 |  |  |  |
| corpus | claude | 137442 | 146547 | 1.07 | 11.3 | 5.4 | 20 | 34.3 | 9073 |
| corpus | codex | 143921 | 255401 | 1.77 | 65.7 | 39.2 | 21 | 99.0 | 111471 |
| corpus | all | 281363 | 401948 | 1.43 | 45.9 | 22.7 |  |  |  |
