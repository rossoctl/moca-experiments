#!/usr/bin/env bash
# pull.sh: copy the metal calibration outputs into e15/results/metal/ (records, params, sessions,
# baseline.json, analysis, calls.jsonl; samples/worker logs gzipped for the N=8 and control rungs).
set -euo pipefail
K=$HOME/.ssh/id_ed25519; R=ubuntu@${RIG_IP:?set RIG_IP}
D=/tmp/kagenti/mx-metalrun/e15/results/metal
ssh -o BatchMode=yes -i $K $R 'set -e; S=/tmp/e15-metal-pull; rm -rf $S; mkdir -p $S
cd /srv/e15/runs
for d in default/*/N1 default/*/N1-s* mem512/*/N1 mem512/*/N1-s*; do
  [ -d "$d" ] || continue
  case "$d" in */_*) continue ;; esac
  mkdir -p $S/baseline/$d
  for f in record.json params.json sessions.jsonl calls.jsonl baseline.json; do [ -f $d/$f ] && cp $d/$f $S/baseline/$d/; done
done
for d in default/*/N1-probe-* mem512/*/N1-probe-*; do
  [ -d "$d" ] || continue
  mkdir -p $S/baseline/$d
  for f in record.json params.json calls.jsonl; do [ -f $d/$f ] && cp $d/$f $S/baseline/$d/; done
done
for d in */*/N*-cal */*/N*-cal-repeat; do
  [ -d "$d" ] || continue
  p=${d%%/*}; rest=${d#*/}; arm=${rest%%/*}; n=${rest#*/}
  t=$S/rungs/$p-$arm-$n; mkdir -p $t
  for f in record.json params.json sessions.jsonl calls.jsonl analysis.json driver-cpu.jsonl; do [ -f $d/$f ] && cp $d/$f $t/; done
  [ -f $d/samples.jsonl ] && gzip -c $d/samples.jsonl > $t/samples.jsonl.gz
  [ -f $d/worker.log ] && gzip -c $d/worker.log > $t/worker.log.gz
done
mkdir -p $S/lifecycle; cp /srv/e15/calibration-metal/lifecycle/{bench.json,summary.json} $S/lifecycle/ 2>/dev/null || true
cp /srv/e15/calibration-metal/chain.out $S/ 2>/dev/null || true
for f in disk_read_max_mbs disk_read_single_mbs disk_read_source artifacts host_profile; do cp /srv/e15/state/$f $S/state-$f.txt 2>/dev/null || true; done
cp /srv/e15/src/COMMIT $S/state-src-COMMIT.txt'
rsync -a -e "ssh -o BatchMode=yes -i $K" $R:/tmp/e15-metal-pull/ $D/
du -sh $D
