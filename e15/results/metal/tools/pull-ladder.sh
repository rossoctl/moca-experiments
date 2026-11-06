#!/usr/bin/env bash
# pull-ladder.sh POINT ARM: copy one metal ladder's rungs into e15/results/metal/POINT/ARM/ (records, params, calls,
# sessions, driver-cpu; samples and worker.log gzipped), plus ladder.json, ladder-rungs.jsonl and the chain log.
set -euo pipefail
P=$1; A=$2
K=/Users/paolo/.ssh/id_ed25519; R=ubuntu@3.218.223.125
D=/tmp/kagenti/mx-metalrun/e15/results/metal/$P/$A
ssh -o BatchMode=yes -i $K $R "set -e; S=/tmp/e15-lp/$P/$A; rm -rf \$S; mkdir -p \$S; cd /srv/e15/runs/$P/$A
cp ladder.json \$S/ 2>/dev/null || true; cp ladder-rungs.part1.jsonl ladder.part2.json \$S/ 2>/dev/null || true; cp /srv/e15/ladders-metal/$P-$A.log \$S/ladder.log; cp /srv/e15/ladders-metal/$P-$A.part1.log \$S/ 2>/dev/null || true
for d in N*; do
  case \$d in N1-s*|N1-probe-*|*-cal|*-cal-repeat|N1.prev-*|probe-corpora) continue ;; esac
  [ -f \$d/record.json ] || continue
  mkdir -p \$S/\$d
  for f in record.json params.json calls.jsonl sessions.jsonl driver-cpu.jsonl attach-probe.log; do [ -f \$d/\$f ] && cp \$d/\$f \$S/\$d/; done
  [ -f \$d/samples.jsonl ] && gzip -c \$d/samples.jsonl > \$S/\$d/samples.jsonl.gz
  [ -f \$d/worker.log ] && gzip -c \$d/worker.log > \$S/\$d/worker.log.gz
done
rm -f \$S/N1/baseline.json"
mkdir -p "$D"
rsync -a -e "ssh -o BatchMode=yes -i $K" $R:/tmp/e15-lp/$P/$A/ "$D/"
du -sh "$D"
