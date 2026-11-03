#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2153  # E15_P_* are read by the sourcing scripts; E15_* come from lib.sh
# e15/rig/points.sh -- the points of SPEC §10.3: what each POINT replays, with which library, on
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
#     E15_P_SCAN_CLASSES  classes whose invocations first scan data.bin (comma-separated; empty: none)
#     E15_P_SCAN_CMD      the scan
#   e15_point_arms POINT  echo E15_P_ARMS, or return 1 for an unknown POINT
#   e15_templates         the distinct templates setup.sh builds, one POINT per line
#
# mem512 (memory pressure): the default point's corpus, with a 512 MiB incompressible data.bin in
# every workspace that the read, shell_read, search, test, interpreter and lint_check calls scan
# first. A resident VM's page cache keeps it after the first scan; each SBX call reads it afresh.

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
  case "$1" in
  default) E15_P_ARMS="sbx resident-inf resident-300 control" ;;
  short) E15_P_ARMS="sbx resident-inf" ;;
  long | no-infra | no-chains) E15_P_ARMS="sbx resident-inf resident-300" ;;
  # smoke: the bring-up point, a dense subset of the default corpus, every arm.
  smoke) E15_P_ARMS="sbx resident-inf resident-300 control" ;;
  mem512)
    E15_P_ARMS="sbx resident-inf"
    E15_P_CORPUS=default
    E15_P_LIBRARY=$E15_SRC/commands/library-mem512.json
    E15_P_TEMPLATE=$E15_ROOT/template-mem512/workspace.img
    E15_P_TEMPLATE_STAMP=template-mem512
    E15_P_IMAGE_MB=1024
    E15_P_DATASET_MIB=512
    E15_P_DATASET_SEED=1
    E15_P_SCAN_CLASSES=$E15_MEM512_SCAN_CLASSES
    E15_P_SCAN_CMD=$E15_MEM512_SCAN_CMD
    ;;
  *) return 1 ;;
  esac
}

e15_point_arms() {
  e15_point "$1" || return 1
  echo "$E15_P_ARMS"
}

e15_templates() { printf '%s\n' default mem512; }
