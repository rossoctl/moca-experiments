# Paths before and after the 2026-11 reorganization

On 2026-11-11 every experiment moved under `experiments/`, one directory per experiment
named `<id>-<slug>`. Old links and clones that still use the previous layout map as
follows. Reference numbers and results did not change; only locations did.

| Before | After |
|---|---|
| `knative/` | `experiments/e01-e07-knative/` |
| `experiments/` | `experiments/e02-e05-harness/` |
| `microvm/` | `experiments/e10-e13-microvm/` |
| `sbx/` | `experiments/e14-sbx/` |
| `e15/` | `experiments/e15-session-density/` |
| `e15/SPEC-bundled.md` | `experiments/e15b-bundled/SPEC.md` |
| `e16/` | `experiments/e16-low-duty/` |
| `e17/` | `experiments/e17-lease/` |
| `e18/` | `experiments/e18-crash-recovery/` |

`analysis/`, `data/`, `docs/` and `scripts/` kept their names.

The `data-v1` and `data-v2` release archives still carry the old member paths; the fetch
scripts map them (see `data/MANIFEST.md`). Git history was preserved with `git mv`, so
`git log --follow` and `git blame` reach the pre-move history.
