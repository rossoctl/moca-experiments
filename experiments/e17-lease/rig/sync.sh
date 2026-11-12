#!/usr/bin/env bash
# experiments/e17-lease/rig/sync.sh (laptop): rsync this worktree's experiments/e15-session-density/, experiments/e16-low-duty/ and experiments/e17-lease/ to the metal host (results/,
# predictions and caches excluded, as experiments/e16-low-duty/rig/sync.sh), write src/COMMIT, install E15's metal-measured
# library over commands/library.json (as experiments/e16-low-duty/rig/sync.sh), and stage E17's inputs:
#   the pycache corpora (experiments/e17-lease/extract/pycache_corpus.py: corpus.jsonl + corpus-report.json)
#     $E17_CORPORA/<point>/ -> /srv/e15/corpora/<point>/   for point pycache, pycache-low
#     (setup.sh step 8c checks each against its report's corpus_sha256 and records it)
#   the venv wheels (experiments/e17-lease/workload/wheels.lock)
#     $E17_WHEELS/ -> /srv/e15/wheels-pycache/   (not /srv/e15/wheels: those are E15's pytest wheels,
#     part of E15's rootfs key; build_pycache_workspace.sh --wheels checks these against the lock)
# The library (experiments/e17-lease/workload/library.json) arrives with experiments/e17-lease/. E17_CORPORA defaults to
# /tmp/kagenti/e17-corpora, E17_WHEELS to /tmp/kagenti/e17-wheels-probe. Run by the controller only.
set -euo pipefail
K=$HOME/.ssh/id_ed25519
H=ubuntu@${RIG_IP:?set RIG_IP}
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
rsync -a --delete --include '*.whl' --exclude '*' -e "$S" "$WH/" "$H:/srv/e15/wheels-pycache/"
$S "$H" 'cat /srv/e15/src/COMMIT; sha256sum /srv/e15/src/e17/workload/library.json /srv/e15/corpora/pycache/corpus.jsonl /srv/e15/corpora/pycache-low/corpus.jsonl; ls /srv/e15/wheels-pycache | wc -l'
