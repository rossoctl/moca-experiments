(
cd project && git diff --exit-code --stat a80f1c56f513a2758445372f263efae6f7337561 8c1a6ef241b51ff055e89219f050ccf4f15f37f6
); __rc=$?; [ "$__rc" -eq 1 ] || { echo "E15_FAILED_STEP=0 RC=$__rc" >&2; exit 90; }
(
cd project && grep -rn 'E15_NO_SUCH_TOKEN_42' more_itertools tests
); __rc=$?; [ "$__rc" -eq 1 ] || { echo "E15_FAILED_STEP=1 RC=$__rc" >&2; exit 91; }
(
cd project && ls
); __rc=$?; [ "$__rc" -eq 0 ] || { echo "E15_FAILED_STEP=2 RC=$__rc" >&2; exit 92; }
exit 0
