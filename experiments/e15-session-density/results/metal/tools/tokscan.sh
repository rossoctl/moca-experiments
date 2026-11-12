#!/usr/bin/env bash
# tokscan.sh DIR: count occurrences of the rig's secret values (exec token, relay tokens) in DIR, gz included.
set -uo pipefail
S=$(mktemp)
ssh -o BatchMode=yes -i $HOME/.ssh/id_ed25519 ubuntu@${RIG_IP:?set RIG_IP} 'sudo cat /srv/e15/secrets/exec.token; echo; sudo grep -h "TOKEN=" /srv/e15/secrets/*.env | cut -d= -f2' >"$S"
hits=0
while read -r s; do
  [ ${#s} -ge 12 ] || continue
  n=$(grep -rlF -- "$s" "$1" | wc -l)
  for z in $(find "$1" -name '*.gz'); do gzip -dc "$z" | grep -qF -- "$s" && n=$((n + 1)); done
  hits=$((hits + n))
done <"$S"
rm -f "$S"
echo "token hits: $hits"
