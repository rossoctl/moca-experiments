#!/usr/bin/env bash
# experiments/e16-low-duty/rig/sync.sh (laptop): rsync this worktree's experiments/e15-session-density/ and experiments/e16-low-duty/ to the metal host (results/, predictions
# and caches excluded), write src/COMMIT, install E15's metal-measured library over commands/library.json
# (as E15's tools/sync.sh), and stage the lowduty corpus (+ report) in /srv/e15/corpora/lowduty/.
# E16_LOWDUTY: the duty_band.py output dir (default /tmp/kagenti/e16-lowduty).
set -euo pipefail
K=$HOME/.ssh/id_ed25519
H=ubuntu@${RIG_IP:?set RIG_IP}
S="ssh -o BatchMode=yes -i $K"
W="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LD=${E16_LOWDUTY:-/tmp/kagenti/e16-lowduty}
cd "$W"
! git status --porcelain -- experiments/e15-session-density experiments/e16-low-duty | grep -qv '^??' || { echo "sync.sh: uncommitted changes under experiments/e15-session-density/ or experiments/e16-low-duty/" >&2; exit 1; }
X=(--exclude results/ --exclude predictions.json --exclude predictions-metal.json --exclude __pycache__ --exclude .pytest_cache)
rsync -a --delete "${X[@]}" -e "$S" experiments/e15-session-density/ "$H:/srv/e15/src/e15/"
$S "$H" 'mkdir -p /srv/e15/src/e16 /srv/e15/corpora/lowduty'
rsync -a --delete "${X[@]}" -e "$S" experiments/e16-low-duty/ "$H:/srv/e15/src/e16/"
git rev-parse HEAD | $S "$H" 'cat > /srv/e15/src/COMMIT'
rsync -a -e "$S" experiments/e15-session-density/results/metal/library.json "$H:/srv/e15/src/e15/commands/library.json"
rsync -a -e "$S" "$LD/corpus.jsonl" "$LD/corpus-report.json" "$H:/srv/e15/corpora/lowduty/"
$S "$H" 'cat /srv/e15/src/COMMIT; sha256sum /srv/e15/src/e15/commands/library.json /srv/e15/corpora/lowduty/corpus.jsonl'
