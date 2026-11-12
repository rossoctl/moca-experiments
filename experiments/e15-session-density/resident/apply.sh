#!/usr/bin/env bash
# apply.sh WORK OUT — build E15's resident-arm worker (SPEC §6.4).
#
# Clones moca at v0.9.0 into WORK/moca (or reuses a clone already there), refuses
# unless HEAD is exactly the pinned commit, applies resident.patch, copies
# resident_test.go into remote-worker/internal/vmpool/, runs the patch's own tests,
# checks TestGateNoVMReuse both ways (PASS without E15_RESIDENT, FAIL with it, for
# the reuse reason and no other), and builds OUT/microvm-worker-resident.
#
# The patch is rig-only: it never enters the moca repo, so the stock gate it
# deliberately breaks under E15_RESIDENT=1 stays untouched there.
#
# Environment:
#   MOCA_SRC        where to clone moca from (default: the public GitHub repo)
#   RESIDENT_PATCH  patch to apply (default: resident.patch beside this script);
#                   an EMPTY file applies nothing, which is the RED run
#   GOWORK          defaults to off (the module is built on its own)
#
# KVM-gated tests skip unless SH_KVM=1 (no /dev/kvm on a laptop); on the rig run
# them with SH_KVM=1 set (PLAN Task 7).
set -euo pipefail

PIN=c13d55649777e69ec7649d6fa8c08f4acb1f4e2e
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PATCH=${RESIDENT_PATCH:-$HERE/resident.patch}
TESTFILE=$HERE/resident_test.go
MOCA_SRC=${MOCA_SRC:-https://github.com/rossoctl/moca.git}
export GOWORK=${GOWORK:-off}

die() { printf 'apply.sh: %s\n' "$*" >&2; exit 1; }
say() { printf 'apply.sh: %s\n' "$*"; }
sha256() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
	else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

[ $# -eq 2 ] || die "usage: apply.sh WORK OUT"
WORK=$1
OUT=$2
[ -f "$PATCH" ] || die "no patch at $PATCH"
[ -f "$TESTFILE" ] || die "no test file at $TESTFILE"
mkdir -p "$WORK" "$OUT"
WORK=$(cd "$WORK" && pwd)
OUT=$(cd "$OUT" && pwd)
REPO=$WORK/moca

if [ -d "$REPO/.git" ]; then
	say "reusing $REPO"
else
	say "cloning $MOCA_SRC into $REPO"
	git clone --quiet --no-checkout "$MOCA_SRC" "$REPO"
	git -C "$REPO" -c advice.detachedHead=false checkout --quiet --detach "$PIN"
fi

head=$(git -C "$REPO" rev-parse HEAD)
[ "$head" = "$PIN" ] || die "HEAD of $REPO is $head, not v0.9.0 ($PIN); refusing"
say "HEAD $head (v0.9.0)"

# A reused clone may hold a previous run's patch. Restore the pinned tree under
# remote-worker/ only, so every run applies the patch to pristine v0.9.0.
git -C "$REPO" checkout --quiet -- remote-worker
git -C "$REPO" clean -fdq -- remote-worker
[ -z "$(git -C "$REPO" status --porcelain -- remote-worker)" ] || die "remote-worker/ is not clean after reset"

if [ -s "$PATCH" ]; then
	git -C "$REPO" apply --check "$PATCH" || die "resident.patch does not apply cleanly to v0.9.0"
	git -C "$REPO" apply "$PATCH"
	say "applied $(basename "$PATCH") (patch sha256 $(sha256 "$PATCH"))"
else
	say "WARNING: $PATCH is empty; nothing applied (RED run)"
fi
cp "$TESTFILE" "$REPO/remote-worker/internal/vmpool/resident_test.go"

cd "$REPO/remote-worker"

say "go test ./internal/vmpool/ -run 'Resident|StockUnchanged'"
env -u E15_RESIDENT -u E15_RESIDENT_IDLE_S \
	go test -count=1 ./internal/vmpool/ -run 'Resident|StockUnchanged' -v ||
	die "resident tests FAILED"

say "go test ./internal/vmpool/ (whole package, E15_RESIDENT unset): must PASS"
env -u E15_RESIDENT -u E15_RESIDENT_IDLE_S \
	go test -count=1 ./internal/vmpool/ ||
	die "the patched package FAILED its own stock suite"

say "TestGateNoVMReuse without E15_RESIDENT: must PASS"
env -u E15_RESIDENT -u E15_RESIDENT_IDLE_S \
	go test -count=1 ./internal/vmpool/ -run '^TestGateNoVMReuse$' -v ||
	die "TestGateNoVMReuse FAILED without E15_RESIDENT: the stock path is not unchanged"

say "TestGateNoVMReuse with E15_RESIDENT=1: must FAIL, for reuse"
log=$(mktemp)
trap 'rm -f "$log"' EXIT
set +e
E15_RESIDENT=1 E15_RESIDENT_IDLE_S=0 \
	go test -count=1 ./internal/vmpool/ -run '^TestGateNoVMReuse$' -v >"$log" 2>&1
rc=$?
set -e
cat "$log"
# Exactly this failure: go test exit 1 (a test failed, not a build error, which is
# 2 or more), the fake-launcher subtest failed, and the reason is a second Run on
# one VM -- the property the patch relaxes. Any other failure is a different bug.
[ "$rc" -eq 1 ] || die "expected go test exit 1 under E15_RESIDENT=1, got $rc"
grep -q -- '--- FAIL: TestGateNoVMReuse/fake_launcher_concurrency' "$log" ||
	die "TestGateNoVMReuse/fake_launcher_concurrency did not fail under E15_RESIDENT=1"
grep -q 'a VM must serve exactly one Exec' "$log" ||
	die "TestGateNoVMReuse failed under E15_RESIDENT=1, but not because a VM was reused"
say "TestGateNoVMReuse fails under E15_RESIDENT=1 as asserted (VM reuse)"

say "building $OUT/microvm-worker-resident"
go build -o "$OUT/microvm-worker-resident" ./cmd/microvm-worker
say "done: $OUT/microvm-worker-resident (moca $PIN + $(basename "$PATCH"))"
