# E17a follow-ups (2026-11-12)

Three one-off checks run after the E17a report, for the lease design revision (rossoctl/moca#718,
lease spec v0.2 §16 items 5 and 6). They ran on the E15 metal host, with 1024 MiB guests and Firecracker
v1.17.0, and are logged in the rig's `~/e17-manifest.md`. They are not sealed measurements: each is
a small, controlled comparison, and the scripts and their output are here.

## 1. Does a restored VM's balloon return freed memory? (`fpr-build.sh`, `fprtest.sh`, `fprtest.txt`)

`fpr-build.sh` builds one test snapshot (`/srv/e15/snapshots/e17-fpr`) from a scratch clone of the
pinned moca checkout. The only change is one line in `build-snapshot.sh`, before `InstanceStart`:
`PUT /balloon {"amount_mib":0,"deflate_on_oom":false,"free_page_reporting":true}`. `fprtest.sh`
restores it through the worker (the `File` backend), beside the unchanged `e15` snapshot as a
control. In each VM a guest process touches 700 MiB and exits, and the VM cgroup's `memory.current`
is read on the host:

| After exit | `e15` (no balloon) | `e17-fpr` (reporting) |
|---|---|---|
| before | 13 MiB | 13 MiB |
| at exit | 734 MiB | 734 MiB |
| +5 s | 734 MiB | 227 MiB |
| +15 s to +60 s | 734 MiB | 81 MiB |

**Yes.** A restored VM keeps reporting and returns about 650 MiB within 15 s.

## 2. Does the balloon cost per-`Exec`? (`perexec-balloon.sh`, `perexec-balloon.txt`)

User decision: one golden snapshot with the balloon, for every mode. Per-`Exec` latency was
measured through the relay with an `sbx` worker, in rounds `e15`, `e17-fpr`, `e15`, `e17-fpr`:

| Command | `e15` median / p95 | `e17-fpr` median / p95 |
|---|---|---|
| `true` (n = 80) | 83 / 96 ms | 85 / 107 ms |
| `python3 -c pass` (n = 40) | 103 / 150 ms | 103 / 150 ms |
| touch 256 MiB (n = 20) | 403 / 412 ms | 403 / 415 ms |

**No measurable cost** (+1 ms median on `true`), and every Exec exited 0.

## 3. How much does level 2 save? (`l2spike.sh`, `l2common.py`, `l2q.py`, `l2srv.py`, `l2spike.txt`)

The same two queries ran on the `pycache` workspace (256 MiB of CSV, 6.0 M rows) in three ways:

- **per-`Exec`:** an `sbx` worker, with a fresh VM and process each time;
- **level 1:** the resident patch, with a warm VM and a fresh process each time;
- **level 2:** one persistent Python server in the same resident VM, started once and queried over a
  unix socket. The resident patch kills no process, so it stands in for `process_start`.

| Query | Per-`Exec` | Level 1 | Level 2 |
|---|---|---|---|
| light: group means + one median over all rows | 6.5 s | 5.4 s (−17%) | **0.25 s (−96%)** |
| fit: `analyze.py`'s KMeans on the 200k sample | 17.4 s | 16.5 s (−5%) | **11.2 s (−36%)** |

The server took 5.4 s from start to ready (import plus parse, paid once). It held 508 MB resident
in the 1 GiB guest, leaving 342 MB available. That memory is live, so free-page reporting cannot
return it, and a level-2 lease is charged its working set. In the first run (log kept on the rig as
`l2spike.run1-oom.log`), the light query took quantiles over all six columns and was OOM-killed in
every mode, including the server. It was replaced by a one-column median.

**Level 2 is the latency case.** A re-query of loaded state is 26× faster than per-`Exec`. A
recompute saves the import and parse (about 6 s). Level 1 alone saves 5–17%.
