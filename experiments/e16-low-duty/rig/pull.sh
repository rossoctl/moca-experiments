#!/usr/bin/env bash
# experiments/e16-low-duty/rig/pull.sh ARM (laptop): re-judge every lowduty ARM ladder/seed/control rung on the host with the
# supplementary rules (record_1s.json: condition 4 at 1000 ms; record_cpu.json: conditions 1-3), then
# copy them into experiments/e16-low-duty/results/ARM/: ladder.json, experiments/e16-low-duty/ rows and per-invocation ladder files, each rung's
# record*.json, params, sessions, driver-cpu, perf; calls, samples and worker.log gzipped; chain logs.
# The baselines, probes, cal and long rungs are pulled elsewhere (results/calibration, N256-long).
set -euo pipefail
A=$1
K=$HOME/.ssh/id_ed25519
H=ubuntu@${RIG_IP:?set RIG_IP}
W="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
D=$W/experiments/e16-low-duty/results/$A
# shellcheck disable=SC2087  # expand A/locals on the laptop side on purpose
ssh -o BatchMode=yes -i "$K" "$H" bash -s <<EOF
set -e
S=/tmp/e16-pull/$A; rm -rf \$S; mkdir -p \$S
B=/srv/e15/runs/lowduty/$A
cd \$B
[ -f ladder.json ] && cp ladder.json \$S/
[ -d e16 ] && cp -r e16 \$S/
[ -d e16-supp ] && cp -r e16-supp \$S/
for f in ladder.sealed.json ladder-supp.json; do [ -f \$f ] && cp \$f \$S/; done
for d in N*; do
  case \$d in N1|N1-s*|N1-probe-*|*-cal|*-long|*.prev-*|probe-corpora) continue ;; esac
  [ -f \$d/record.json ] && [ -f \$d/params.json ] || continue
  python3 /srv/e15/src/e15/analysis/record.py \$d --params \$d/params.json --p95-limit-ms 1000 --out \$d/record_1s.json >/dev/null
  python3 /srv/e15/src/e15/analysis/record.py \$d --params \$d/params.json --ignore-c4 --out \$d/record_cpu.json >/dev/null
  # supplementary no-wedge re-judge (writes record_nowedge.json only where the worker log has a wedge)
  [ ! -f \$d/worker.log ] || python3 /srv/e15/src/e16/analysis/nowedge.py \$d >/dev/null
  mkdir -p \$S/\$d
  for f in record.json record_1s.json record_cpu.json record_nowedge.json stag_valid.json params.json sessions.jsonl driver-cpu.jsonl perf.jsonl attach-probe.log; do [ -f \$d/\$f ] && cp \$d/\$f \$S/\$d/; done
  for f in calls.jsonl samples.jsonl worker.log; do [ -f \$d/\$f ] && gzip -c \$d/\$f > \$S/\$d/\$f.gz; done
done
mkdir -p \$S/logs; cp /srv/e15/e16/$A-N*.log \$S/logs/ 2>/dev/null || true; cp /srv/e15/e16/task8.out \$S/logs/ 2>/dev/null || true
du -sh \$S
EOF
mkdir -p "$D"
rsync -a -e "ssh -o BatchMode=yes -i $K" "$H:/tmp/e16-pull/$A/" "$D/"
du -sh "$D"
