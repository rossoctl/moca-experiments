#!/usr/bin/env bash
# e15/results/calibration/guest_test_library.sh -- run e15/commands/test_library.py INSIDE one E15
# VM (Linux, the snapshot's pytest and rg), with E15_WORKSPACE=/workspace: the seeded template
# workspace, exactly as the worker mounts it. The test files go to /workspace/.e15-test (copied in
# over the Exec as base64; the workspace is a throwaway reflink copy).
rm -rf "$OUTDIR"
set -euo pipefail
E15_PROG=guest_test_library.sh
. /srv/e15/src/e15/rig/lib.sh
OUTDIR=${OUTDIR:-/srv/e15/calibration/guest-test}
KEY=e15-calib-test
mkdir -p "$OUTDIR/worker"
trap stop_rung_units EXIT
stop_rung_units
sudo -n rm -rf "$E15_WORKSPACES/$KEY"
sudo -n mkdir -m 0700 "$E15_WORKSPACES/$KEY"
sudo -n cp --reflink=always "$E15_TEMPLATE" "$E15_WORKSPACES/$KEY/workspace.img"
sudo -n chmod 0600 "$E15_WORKSPACES/$KEY/workspace.img"
start_worker resident-inf "$OUTDIR/worker"
b64=$(tar -C "$E15_SRC" --exclude=__pycache__ -czf - commands extract/classes.py | base64 -w0)
# the guest has no tar(1): unpack with python3 -m tarfile
gexec "$KEY" "rm -rf /workspace/.e15-test && mkdir -p /workspace/.e15-test && echo $b64 | base64 -d >/workspace/.e15-test.tgz && python3 -m tarfile -e /workspace/.e15-test.tgz /workspace/.e15-test && rm -f /workspace/.e15-test.tgz && ls /workspace/.e15-test" >"$OUTDIR/stage.txt" 2>&1
T='cd /workspace/.e15-test/commands && python3 -m pytest -q -p no:cacheprovider test_library.py'
# 1: every check except the workspace run (it is the long one; gexec's timeout is 120 s)
gexec "$KEY" "$T -k 'not commands_run_in_workspace' 2>&1 | tail -15" >"$OUTDIR/pytest-rest.txt" 2>&1 && echo "rest: exit 0" >>"$OUTDIR/summary.txt" || echo "rest: exit $?" >>"$OUTDIR/summary.txt"
# 2: the opt-in E15_WORKSPACE check, every invocation against /workspace, in two halves (gexec's
# Exec timeout is 120 s): the slow invocations skipped, then only the slow ones.
SLOW=burn_20000,sleep_10s,pytest_suite,pytest_file_recipes,burn_5000,pytest_file_more,clone_full_x10
ALL_BUT_SLOW=read_head,read_file,read_tree,read_tree_x20,write_note,write_append,edit_1,edit_50,write_tree_200,edit_500,write_tree_2000,edit_2000,rg_def,rg_files,rg_defs,rg_all_x20,rg_all_x100,pytest_one,pytest_k,pytest_class,burn_50,burn_200,burn_1000,py_compile_one,py_compile_pkg,compileall_f,compileall_f_x10,compileall_f_x30,git_status,git_diff_clean,git_diff_prev,git_log_20,git_commit_tree,git_log_p,git_log_p_all,git_fsck,git_log_follow,git_log_p_x5,git_blame,ls,grep_nomatch,wc_py,sed_range,find_sort,grep_cut_uniq,grep_tree_x20,grep_tree_x100,mkdir_touch,cp_mv_rm,cp_tree,cp_tree_x20,tar_gz_roundtrip,sleep_100ms,sleep_1s,nproc,ps_once,ps_watch,ls_remote,clone_bare,loop_wc,subshell_grep,u_burn_1000,file_type,sha256_tree,o_burn_1000
for half in fast slow; do
  if [ $half = fast ]; then skip=$SLOW; else skip=$ALL_BUT_SLOW; fi
  gexec "$KEY" "export E15_SKIP=$skip E15_WORKSPACE=/workspace; $T -k commands_run_in_workspace -rA 2>&1 | tail -15" >"$OUTDIR/pytest-workspace-$half.txt" 2>&1 && echo "workspace-$half: exit 0" >>"$OUTDIR/summary.txt" || echo "workspace-$half: exit $?" >>"$OUTDIR/summary.txt"
done
grep -c 'vmpool: restore phases' "$OUTDIR/worker/worker.log" >"$OUTDIR/vm-restores.txt" || true
