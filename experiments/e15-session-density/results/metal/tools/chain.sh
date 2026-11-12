#!/usr/bin/env bash
# chain.sh -- E15 metal calibration (SPEC §10.1), after the library is measured and installed.
# Steps (each writes a "CHAIN <step> <status>" line on stdout for the monitor):
#   lifecycle bench (sbx, 100 no-op Execs), default baselines sbx/resident-inf/resident-300,
#   control N=128, N=8 calibration rungs sbx/resident-inf at default, mem512 baselines sbx/resident-inf,
#   N=8 calibration rungs sbx/resident-inf at mem512. Stops at the first failing step.
# STEPS env: a space-separated subset to run (default all, in order).
set -uo pipefail
export E15_HOST_PROFILE=fresh-metal
export PATH=/srv/e15/bin:$PATH
unset E15_MAX_SESSIONS E15_START_ZERO E15_TAG E15_SEED E15_WARMUP_S E15_WINDOW_S
R=/srv/e15/src/e15/rig
T=/srv/e15/calibration-metal/tools
L=/srv/e15/calibration-metal/logs
mkdir -p "$L"
ALL="lifecycle base-default-sbx base-default-resident-inf base-default-resident-300 control-N128 cal-default-sbx-N8 cal-default-resident-inf-N8 base-mem512-sbx base-mem512-resident-inf cal-mem512-sbx-N8 cal-mem512-resident-inf-N8"
STEPS=${STEPS:-$ALL}
summ() { # summ RECORD.json
  python3 - "$1" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
ks = ("holds", "holds_abs", "binding", "reason", "failed_calls", "window_calls", "median_class_pace",
      "median_pace", "p95_excess_ms", "excess_limit_ms", "footprint_drift_pct", "repeat_required")
out = {}
for k in ks:
    if k in r:
        v = r[k]
        out[k] = round(v, 4) if isinstance(v, float) else (len(v) if isinstance(v, list) else v)
a2 = (r.get("driver") or {}).get("a2_pct_of_host")
if a2 is not None: out["a2"] = round(a2, 4)
print(json.dumps(out))
PY
}
bsumm() { # bsumm baseline.json
  python3 - "$1" <<'PY'
import json, sys
b = json.load(open(sys.argv[1]))
print(json.dumps({k: (round(b[k], 2) if isinstance(b.get(k), float) else b.get(k)) for k in
  ("excess_p95_ms", "p95_added_ms", "overhead_ms", "n1_median_pace", "undercovered", "probe_failed")}
  | {"evaluable": [e.get("seed") for e in b.get("evaluable", [])], "skipped": [s.get("seed") for s in b.get("skipped", [])]}))
PY
}
for step in $STEPS; do
  echo "CHAIN $step START $(date -u +%FT%TZ)"
  rc=0
  case "$step" in
  lifecycle)
    OUTDIR=/srv/e15/calibration-metal/lifecycle bash "$T/lifecycle_bench.sh" >"$L/$step.log" 2>&1 || rc=$?
    [ $rc -ne 0 ] || res=$(python3 "$T/calib_analyze.py" lifecycle /srv/e15/calibration-metal/lifecycle | tee /srv/e15/calibration-metal/lifecycle/summary.json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps({"core_s_per_exec": d["core_s_per_exec"], "phase_median_ms": d["phase_median_ms"]}))')
    ;;
  base-*)
    rest=${step#base-}; point=${rest%%-*}; arm=${rest#*-}
    bash "$R/baseline.sh" "$point" "$arm" >"$L/$step.log" 2>&1 || rc=$?
    [ $rc -ne 0 ] || res=$(bsumm "/srv/e15/runs/$point/$arm/N1/baseline.json")
    ;;
  control-N128)
    E15_TAG=cal bash "$R/rung.sh" control 128 default >"$L/$step.log" 2>&1 || rc=$?
    [ $rc -ne 0 ] || res=$(summ /srv/e15/runs/default/control/N128-cal/record.json)
    ;;
  cal-*)
    rest=${step#cal-}; point=${rest%%-*}; rest=${rest#*-}; n=${rest##*-N}; arm=${rest%-N*}
    E15_TAG=cal bash "$R/rung.sh" "$arm" "$n" "$point" >"$L/$step.log" 2>&1 || rc=$?
    d=/srv/e15/runs/$point/$arm/N$n-cal
    if [ $rc -eq 0 ]; then
      kind=sbx; [ "$arm" = sbx ] || kind=resident
      E15_LIBRARY=/srv/e15/src/e15/commands/library.json python3 "$T/calib_analyze.py" "$kind" "$d" >"$d/analysis.json" 2>"$L/$step.analyze.err" || true
      res="$(summ "$d/record.json") $(python3 -c 'import json,sys
try: a=json.load(open(sys.argv[1]))
except Exception: print("{}"); raise SystemExit
print(json.dumps({k: round(a[k],3) for k in ("core_s_per_call","footprint_median_mib","footprint_max_mib","usable_mib","host_cpu_busy_pct_mean") if a.get(k) is not None}))' "$d/analysis.json")"
    fi
    ;;
  *) echo "CHAIN $step UNKNOWN"; exit 2 ;;
  esac
  if [ $rc -ne 0 ]; then
    echo "CHAIN $step FAILED rc=$rc $(date -u +%FT%TZ) :: $(tail -3 "$L/$step.log" | tr '\n' ' ' | cut -c1-400)"
    exit 1
  fi
  echo "CHAIN $step DONE $(date -u +%FT%TZ) :: $res"
done
echo "CHAIN ALL DONE $(date -u +%FT%TZ)"
