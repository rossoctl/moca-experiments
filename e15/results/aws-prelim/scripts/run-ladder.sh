#!/usr/bin/env bash
# ~/e15-run/t9/run-ladder.sh POINT ARM [START]: one ladder, detached; log + exit marker in ~/e15-run/t9/
set -u
P=$1 A=$2 S=${3:-1}
L=~/e15-run/t9/$P-$A.log
export PATH=/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin
echo "start $(date -u +%FT%TZ) $P $A $S" >"$L"
bash /srv/e15/src/e15/rig/ladder.sh "$P" "$A" "$S" >>"$L" 2>&1
rc=$?
echo "exit $rc $(date -u +%FT%TZ)" >>"$L"
echo "$rc" >~/e15-run/t9/$P-$A.done
