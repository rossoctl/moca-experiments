#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2153  # E15_P_* are read by the sourcing scripts; E15_* come from lib.sh
# experiments/e15-session-density/rig/points.sh -- the points of SPEC §10.3: what each POINT replays, with which library, on
# which workspace template. Sourced after lib.sh (needs E15_ROOT, E15_SRC, E15_TEMPLATE), never run.
# Sourcing has no side effects. rung.sh, baseline.sh, classprobe.sh, ladder.sh and setup.sh use it.
#
#   e15_point POINT   sets, or returns 1 for an unknown POINT:
#     E15_P_ARMS          the arms the point runs (SPEC §10.3)
#     E15_P_CORPUS        corpus directory name under $E15_CORPORA
#     E15_P_LIBRARY       command library the driver replays
#     E15_P_TEMPLATE      workspace template image copied per session key
#     E15_P_TEMPLATE_STAMP  setup.sh's build stamp for that template (in $E15_STATE)
#     E15_P_IMAGE_MB      the template's size; the rung's SH_WORKSPACE_IMAGE_MB
#     E15_P_DATASET_MIB   /workspace/data.bin size in MiB (0: none)
#     E15_P_DATASET_SEED  data.bin's seed
#     E15_P_SCAN_CLASSES  classes whose calls open with the scan (driver --scan-classes; empty: none)
#     E15_P_SCAN_CMD      the scan, run ONCE per recorded call of those classes (driver --scan-cmd)
#     E15_P_FALLBACK      1: with no pooled runs of its own, the point may use the default point's
#                         N=1 baseline (rung.sh); 0 for default itself and for mem512
#     E15_P_PROBE_CAP_MS  the class probe's cap on planned durations (classprobe.sh -> make_probe.py
#                         --cap-ms); set by the pycache points only, unset otherwise (classprobe.sh:
#                         30000, make_probe.py's own default)
#     E15_P_SETTINGS      the point's settings line (point name, corpus, library, template, image
#                         size, dataset, scan; then probe_cap_ms only where the cap is set); its
#                         sha256 is the point signature
#   e15_point_sig POINT   echo the point signature: sha256 of E15_P_SETTINGS. rung.sh records it in
#                         params.json/record.json, baseline.py in baseline.json, and rung.sh refuses
#                         a baseline whose point_sig is not the one it expects
#   e15_point_arms POINT  echo E15_P_ARMS, or return 1 for an unknown POINT
#   e15_templates         the distinct templates setup.sh builds, one POINT per line
#
# mem512 (memory pressure): the default point's corpus and library, with a 512 MiB incompressible
# data.bin in every workspace; each call of read, shell_read, search, test, interpreter or
# lint_check reads it once first (the driver's scan step). A resident VM's page cache keeps it
# after the first read; each SBX call reads it afresh. Its library and corpus hashes equal the
# default point's, so the point signature is what keeps the two points' baselines apart.
#
# pycache, pycache-low, pycache-d64, pycache-d768 (E17, experiments/e17-lease/SPEC.md; fresh-metal only, any other
# profile returns 1): E17's generated corpora and library (experiments/e17-lease/extract/pycache_corpus.py,
# experiments/e17-lease/workload/library.json), 1536 MiB workspaces with a D MiB dataset and the venv. pycache replays
# the 9.5% duty corpus, pycache-low the 1.5% one, both on the D=256 template; pycache-d64 and
# pycache-d768 replay the pycache corpus on the D=64 and D=768 templates. The templates
# (template-pycache-d<D>, stamp template-pycache-d<D>) are built by experiments/e17-lease/rig/bringup.sh, not
# setup.sh, so e15_templates is E15's. No fallback: each point needs its own baselines.
# Probe cap 120000 ms (E17 Task 5b): pycache's py_test runs ~62 s whatever it is planned at, so
# E15's 30 000 ms cap made its probe median +31 s. The cap is in these points' settings, so a
# baseline probed under another cap has another point_sig and rung.sh refuses it.

E15_MEM512_SCAN_CLASSES=read,shell_read,search,test,interpreter,lint_check
E15_MEM512_SCAN_CMD='cat /workspace/data.bin >/dev/null'

e15_point() {
  E15_P_CORPUS=$1
  E15_P_LIBRARY=$E15_SRC/commands/library.json
  E15_P_TEMPLATE=$E15_TEMPLATE
  E15_P_TEMPLATE_STAMP=template
  E15_P_IMAGE_MB=256
  E15_P_DATASET_MIB=0
  E15_P_DATASET_SEED=1
  E15_P_SCAN_CLASSES=""
  E15_P_SCAN_CMD=""
  E15_P_FALLBACK=1
  # Never defaulted: unset here so a pycache call cannot leak it into the next point's (setup.sh
  # calls e15_point for several points in one shell).
  unset E15_P_PROBE_CAP_MS
  case "$1" in
  default)
    E15_P_ARMS="sbx resident-inf resident-300 control"
    E15_P_FALLBACK=0
    ;;
  short) E15_P_ARMS="sbx resident-inf" ;;
  # lowduty (E16): the default corpus's sessions with duty cycle in (1%, 2%]
  # (experiments/e16-low-duty/extract/duty_band.py); default library and template; its own baselines, no fallback.
  lowduty)
    E15_P_ARMS="sbx resident-inf control"
    E15_P_FALLBACK=0
    ;;
  long | no-infra | no-chains) E15_P_ARMS="sbx resident-inf resident-300" ;;
  # smoke: the bring-up point, a dense subset of the default corpus, every arm.
  smoke) E15_P_ARMS="sbx resident-inf resident-300 control" ;;
  mem512)
    E15_P_ARMS="sbx resident-inf"
    E15_P_CORPUS=default
    E15_P_TEMPLATE=$E15_ROOT/template-mem512/workspace.img
    E15_P_TEMPLATE_STAMP=template-mem512
    E15_P_IMAGE_MB=1024
    E15_P_DATASET_MIB=512
    E15_P_DATASET_SEED=1
    E15_P_SCAN_CLASSES=$E15_MEM512_SCAN_CLASSES
    E15_P_SCAN_CMD=$E15_MEM512_SCAN_CMD
    E15_P_FALLBACK=0
    ;;
  pycache | pycache-low | pycache-d64 | pycache-d768)
    [ "$E15_HOST_PROFILE" = fresh-metal ] || return 1
    E15_P_ARMS="sbx resident-300 lease-30 lease-120"
    E15_P_CORPUS=pycache
    [ "$1" != pycache-low ] || E15_P_CORPUS=pycache-low
    E15_P_LIBRARY=$E15_ROOT/src/e17/workload/library.json
    case "$1" in
    pycache-d64) E15_P_DATASET_MIB=64 ;;
    pycache-d768) E15_P_DATASET_MIB=768 ;;
    *) E15_P_DATASET_MIB=256 ;;
    esac
    E15_P_DATASET_SEED=1
    E15_P_TEMPLATE_STAMP=template-pycache-d$E15_P_DATASET_MIB
    E15_P_TEMPLATE=$E15_ROOT/$E15_P_TEMPLATE_STAMP/workspace.img
    E15_P_IMAGE_MB=1536
    E15_P_FALLBACK=0
    E15_P_PROBE_CAP_MS=120000
    ;;
  *) return 1 ;;
  esac
  E15_P_SETTINGS="point=$1 corpus=$E15_P_CORPUS library=${E15_P_LIBRARY#"$E15_ROOT"/} template=${E15_P_TEMPLATE#"$E15_ROOT"/}"
  E15_P_SETTINGS+=" image_mb=$E15_P_IMAGE_MB dataset_mib=$E15_P_DATASET_MIB dataset_seed=$E15_P_DATASET_SEED"
  E15_P_SETTINGS+=" scan_classes=$E15_P_SCAN_CLASSES scan_cmd=$E15_P_SCAN_CMD"
  [ -z "${E15_P_PROBE_CAP_MS:-}" ] || E15_P_SETTINGS+=" probe_cap_ms=$E15_P_PROBE_CAP_MS"
}

e15_point_sig() {
  e15_point "$1" || return 1
  printf '%s' "$E15_P_SETTINGS" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
}

e15_point_arms() {
  e15_point "$1" || return 1
  echo "$E15_P_ARMS"
}

e15_templates() { printf '%s\n' default mem512; }
