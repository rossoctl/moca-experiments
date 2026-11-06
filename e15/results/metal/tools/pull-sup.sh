#!/usr/bin/env bash
# pull-sup.sh ARM: copy the supplementary climb of a default arm into e15/results/metal/default/ARM/supplementary-1s/:
# climb.json/.jsonl, the new N<k>-1s* rungs (records incl. record_1s/record_cpu, params, calls, sessions, perf; samples
# and worker.log gzipped) and the record_1s/record_cpu re-judges of the sealed rungs (as sealed-rejudge/N<k>/).
set -euo pipefail
A=$1
K=/Users/paolo/.ssh/id_ed25519; R=ubuntu@3.218.223.125
D=/tmp/kagenti/mx-metalrun2/e15/results/metal/default/$A/supplementary-1s
ssh -o BatchMode=yes -i $K $R "set -e; S=/tmp/e15-sup/$A; rm -rf \$S; mkdir -p \$S/sealed-rejudge; B=/srv/e15/runs/default/$A
cp \$B/supplementary-1s/climb.json* \$B/supplementary-1s/climb.jsonl \$S/ 2>/dev/null || true
for d in \$B/N*-1s*; do [ -d \$d ] || continue; n=\$(basename \$d); mkdir -p \$S/\$n
  for f in record.json record_1s.json record_cpu.json params.json calls.jsonl sessions.jsonl driver-cpu.jsonl perf.jsonl; do [ -f \$d/\$f ] && cp \$d/\$f \$S/\$n/; done
  [ -f \$d/samples.jsonl ] && gzip -c \$d/samples.jsonl > \$S/\$n/samples.jsonl.gz
  [ -f \$d/worker.log ] && gzip -c \$d/worker.log > \$S/\$n/worker.log.gz
done
for d in \$B/N*; do case \$(basename \$d) in *-1s*) continue;; esac
  [ -f \$d/record_1s.json ] || continue; mkdir -p \$S/sealed-rejudge/\$(basename \$d); cp \$d/record_1s.json \$d/record_cpu.json \$S/sealed-rejudge/\$(basename \$d)/; done
cp /srv/e15/ladders-metal/climb-$A-*.log \$S/ 2>/dev/null || true"
mkdir -p "$D"
rsync -a -e "ssh -o BatchMode=yes -i $K" $R:/tmp/e15-sup/$A/ "$D/"
du -sh "$D"
