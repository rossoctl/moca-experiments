#!/usr/bin/env bash
# experiments/e17-lease/rig/sync.sh (laptop): rsync this worktree's experiments/e15-session-density/, experiments/e16-low-duty/ and experiments/e17-lease/ to the metal host (results/,
# predictions and caches excluded, as experiments/e16-low-duty/rig/sync.sh), write src/COMMIT, install E15's metal-measured
# library over commands/library.json (as experiments/e16-low-duty/rig/sync.sh), and stage E17's inputs:
#   the pycache corpora (experiments/e17-lease/extract/pycache_corpus.py: corpus.jsonl + corpus-report.json)
#     $E17_CORPORA/<point>/ -> /srv/e15/corpora/<point>/   for point pycache, pycache-low, and under E17C=1
#     pycache-256 when gen_corpora.sh --gate-256 wrote it (E17c's 256 MiB points, PLAN-E17C Task 10)
#     and under E17D=1 pycache-l2 (E17d's level-2 point, PLAN-E17D Task 3; required then)
#     (setup.sh step 8c checks each against its report's corpus_sha256 and records it)
#   the venv wheels (experiments/e17-lease/workload/wheels.lock)
#     $E17_WHEELS/ -> /srv/e15/wheels-pycache/   (not /srv/e15/wheels: those are E15's pytest wheels,
#     part of E15's rootfs key; build_pycache_workspace.sh --wheels checks these against the lock)
# The library (experiments/e17-lease/workload/library.json) arrives with experiments/e17-lease/. E17_CORPORA defaults to
# /tmp/kagenti/e17-corpora, E17_WHEELS to /tmp/kagenti/e17-wheels-probe. Run by the controller only.
set -euo pipefail
K=${E17_RIG_KEY:-$HOME/.ssh/id_ed25519}
# The rig host: the AWS rig's ubuntu@<RIG_IP>. E17_RIG_HOST names another, e.g. the SBX0 metal host's
# ssh alias (sbx-kvm, user dettori), with E17_RIG_KEY for its key (E17D-D1).
H=${E17_RIG_HOST:-ubuntu@${RIG_IP:?set RIG_IP, or E17_RIG_HOST for another host}}
S="ssh -o BatchMode=yes -i $K"
W="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PC=${E17_CORPORA:-/tmp/kagenti/e17-corpora}
WH=${E17_WHEELS:-/tmp/kagenti/e17-wheels-probe}
cd "$W"
! git status --porcelain -- experiments/e15-session-density experiments/e16-low-duty experiments/e17-lease | grep -qv '^??' || { echo "sync.sh: uncommitted changes under experiments/" >&2; exit 1; }
for p in pycache pycache-low; do
  for f in corpus.jsonl corpus-report.json; do
    [ -f "$PC/$p/$f" ] || { echo "sync.sh: no $PC/$p/$f (run e17/extract/pycache_corpus.py)" >&2; exit 1; }
  done
done
if [ "${E17D:-}" = 1 ]; then
  for f in corpus.jsonl corpus-report.json; do
    [ -f "$PC/pycache-l2/$f" ] || { echo "sync.sh: no $PC/pycache-l2/$f (E17D=1: run gen_corpora.sh with E17D=1)" >&2; exit 1; }
  done
fi
[ -n "$(find "$WH" -maxdepth 1 -name '*.whl' -print -quit 2>/dev/null)" ] || { echo "sync.sh: no wheels in $WH" >&2; exit 1; }
X=(--exclude results/ --exclude predictions.json --exclude predictions-metal.json --exclude __pycache__ --exclude .pytest_cache)
rsync -a --delete "${X[@]}" -e "$S" experiments/e15-session-density/ "$H:/srv/e15/src/e15/"
$S "$H" 'mkdir -p /srv/e15/src/e16 /srv/e15/src/e17 /srv/e15/corpora/pycache /srv/e15/corpora/pycache-low /srv/e15/wheels-pycache'
rsync -a --delete "${X[@]}" -e "$S" experiments/e16-low-duty/ "$H:/srv/e15/src/e16/"
rsync -a --delete "${X[@]}" -e "$S" experiments/e17-lease/ "$H:/srv/e15/src/e17/"
git rev-parse HEAD | $S "$H" 'cat > /srv/e15/src/COMMIT'
rsync -a -e "$S" experiments/e15-session-density/results/metal/library.json "$H:/srv/e15/src/e15/commands/library.json"
for p in pycache pycache-low; do
  rsync -a -e "$S" "$PC/$p/corpus.jsonl" "$PC/$p/corpus-report.json" "$H:/srv/e15/corpora/$p/"
done
if [ "${E17C:-}" = 1 ] && [ -f "$PC/pycache-256/corpus.jsonl" ] && [ -f "$PC/pycache-256/corpus-report.json" ]; then
  $S "$H" 'mkdir -p /srv/e15/corpora/pycache-256'
  rsync -a -e "$S" "$PC/pycache-256/corpus.jsonl" "$PC/pycache-256/corpus-report.json" "$H:/srv/e15/corpora/pycache-256/"
fi
if [ "${E17D:-}" = 1 ]; then
  $S "$H" 'mkdir -p /srv/e15/corpora/pycache-l2'
  rsync -a -e "$S" "$PC/pycache-l2/corpus.jsonl" "$PC/pycache-l2/corpus-report.json" "$H:/srv/e15/corpora/pycache-l2/"
fi
rsync -a --delete --include '*.whl' --exclude '*' -e "$S" "$WH/" "$H:/srv/e15/wheels-pycache/"
$S "$H" 'cat /srv/e15/src/COMMIT; sha256sum /srv/e15/src/e17/workload/library.json /srv/e15/corpora/pycache/corpus.jsonl /srv/e15/corpora/pycache-low/corpus.jsonl; ls /srv/e15/wheels-pycache | wc -l'
