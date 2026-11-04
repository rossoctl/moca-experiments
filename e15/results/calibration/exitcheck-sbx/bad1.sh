(
cd project && ls
); __rc=$?; [ "$__rc" -eq 0 ] || { echo "E15_FAILED_STEP=0 RC=$__rc" >&2; exit 90; }
(
cd project && grep -rn 'E15_NO_SUCH_TOKEN_42' more_itertools tests
); __rc=$?; [ "$__rc" -eq 0 ] || { echo "E15_FAILED_STEP=1 RC=$__rc" >&2; exit 91; }
exit 0
