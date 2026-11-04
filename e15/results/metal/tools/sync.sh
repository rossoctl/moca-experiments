#!/usr/bin/env bash
# sync.sh: rsync the mx-metalrun worktree's e15/ to the metal host (results/ and predictions excluded),
# write src/COMMIT, then (if present) install the metal-measured library over commands/library.json.
set -euo pipefail
K=/Users/paolo/.ssh/id_ed25519; R=ubuntu@3.218.223.125
S="ssh -o BatchMode=yes -i $K"
cd /tmp/kagenti/mx-metalrun
rsync -a --delete --exclude results/ --exclude predictions.json --exclude predictions-metal.json --exclude __pycache__ --exclude .pytest_cache -e "$S" e15/ $R:/srv/e15/src/e15/
git rev-parse HEAD | $S $R 'cat > /srv/e15/src/COMMIT'
if [ -f e15/results/metal/library.json ]; then
  rsync -a -e "$S" e15/results/metal/library.json $R:/srv/e15/src/e15/commands/library.json
fi
$S $R 'cat /srv/e15/src/COMMIT; sha256sum /srv/e15/src/e15/commands/library.json'
