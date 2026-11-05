#!/usr/bin/env bash
# pull.sh: copy measured rung results (not probes/baselines-dirs, not raw logs) into e15/results/<point>/<arm>/<N>/
set -euo pipefail
. /tmp/kagenti/task9-scripts/env.sh
DST=/tmp/kagenti/moca-experiments/e15/results
STAGE=/tmp/kagenti/task9-pull
rm -rf "$STAGE"; mkdir -p "$STAGE"
# on the rig: stage a tarball of what we keep
$S $R 'set -e; cd /srv/e15/runs; rm -rf /tmp/e15pull; mkdir -p /tmp/e15pull
for lj in */*/ladder.json; do
  pa=${lj%/ladder.json}; case "$pa" in _*|smoke/*|*/control) continue;; esac
  mkdir -p /tmp/e15pull/$pa; cp $pa/ladder*.json /tmp/e15pull/$pa/; [ -f $pa/fine.json ] && mkdir -p /tmp/e15pull/$pa/supplementary && cp $pa/fine.json /tmp/e15pull/$pa/supplementary/ || true
  for d in $pa/N*; do
    b=${d##*/}; case "$b" in N1-s*|N1-probe-*|*.prev-*|*-guard|*-cal*) continue;; esac
    [ -f $d/record.json ] || continue
    [ -f $d/shared-host.json ] || python3 ~/e15-run/t9/shared_host.py $d >/dev/null
    n=${b#N}
    case "$n" in *-fine*) n=supplementary/N${n%%-fine*}${n#*-fine};; esac
    mkdir -p /tmp/e15pull/$pa/$n
    for f in record.json params.json calls.jsonl sessions.jsonl samples.jsonl driver-cpu.jsonl worker.log shared-host.json attach-probe.log driver.log; do
      [ -f $d/$f ] && cp $d/$f /tmp/e15pull/$pa/$n/
    done
    [ -f $d/memory-abort ] && cp $d/memory-abort /tmp/e15pull/$pa/$n/ || true
  done
done
# baselines used (small)
for b in */*/N1/baseline.json; do case "$b" in _*|smoke/*) continue;; esac; mkdir -p /tmp/e15pull/${b%/N1/baseline.json}/baseline; cp $b /tmp/e15pull/${b%/N1/baseline.json}/baseline/; done
cd /tmp/e15pull && find . \( -name samples.jsonl -o -name worker.log -o -name calls.jsonl \) -exec gzip -9 -f {} +
tar czf /tmp/e15pull.tgz -C /tmp/e15pull .'
scp -q -i $K $R:/tmp/e15pull.tgz "$STAGE/"
mkdir -p "$STAGE/x"; tar xzf "$STAGE/e15pull.tgz" -C "$STAGE/x"
# secret scan against the rig's actual token values
$S $R 'sudo -n cat /srv/e15/secrets/exec.token; echo; sudo -n cat /srv/e15/secrets/sandbox.token; echo; sudo -n cat /srv/e15/secrets/relay.env /srv/e15/secrets/worker.env | grep -E "TOKEN|SECRET|KEY" | cut -d= -f2- | tr -d "\\042\\047"' >"$STAGE/.tok"
hits=0
while read -r t; do
  [ ${#t} -ge 12 ] || continue
  c=$( (grep -rlF -- "$t" "$STAGE/x" || true; find "$STAGE/x" -name '*.gz' -exec sh -c 'gzip -dc "$1" | grep -qF -- "$2" && echo "$1"' _ {} "$t" \;) | wc -l)
  hits=$((hits + c))
done <"$STAGE/.tok"
rm -f "$STAGE/.tok"
pat=$(grep -rliE "bearer [a-z0-9]{16}|sk-[a-zA-Z0-9]{20}|ghp_[A-Za-z0-9]{20}|AKIA[0-9A-Z]{16}" "$STAGE/x" | wc -l || true)
echo "token-value hits: $hits; pattern hits: $pat"
[ "$hits" -eq 0 ] && [ "$pat" -eq 0 ] || { echo "SECRETS FOUND, not copied"; exit 1; }
rsync -a "$STAGE/x/" "$DST/"
du -sh "$DST"/* | grep -v calibration
