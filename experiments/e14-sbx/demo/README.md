# sbx demo: a first `mocactl sbx up` exercise

A two-file repository with one deliberate bug: `calc.py` implements `add` as
subtraction, so `test_calc.py` (stdlib `unittest`, no dependencies — the sandbox
guest has no network, so anything needing `pip install` cannot run its tests there)
fails. It is the same shape `deploy/sbx/smoke.sh` step 1 uses, sized for a first
session in the MOCA sandbox service.

## The exercise

This demo lives at `experiments/e14-sbx/demo/`, not at the repository root, and that matters for every
command below: `up` binds the whole working tree, and the sandbox runs each command in
`/workspace` — a copy of the repository root. So `run` and `put` paths are relative to
the root no matter which directory you are standing in, and `cd experiments/e14-sbx/demo` on your side
does not move the remote one.

From the **repository root**, with `mocactl` installed and enrolled (your operator gives
you the control-plane URL and adds your GitHub account to the allowlist):

```bash
mocactl sbx login --control-plane-url <URL>   # once; it is remembered

mocactl sbx up                                # push the tree, bind the sandbox, wire the agent config

# the failing test, inside a fresh VM. The `cd` is remote: a bare
# `python3 -m unittest` runs at /workspace, where there is no test to
# find, so it reports "Ran 0 tests" instead of the failure (on the
# guest's Python, that is a silent "OK" and exit 0).
mocactl sbx run -- sh -c 'cd experiments/e14-sbx/demo && python3 -m unittest'

# fix it either way:
claude                                        # the repo's .mcp.json points Claude Code at the
                                              # sandbox; prompt: "The test suite in experiments/e14-sbx/demo
                                              # fails (cd experiments/e14-sbx/demo && python3 -m unittest).
                                              # Fix it with a minimal change and run the tests."
# or by hand (the path is /workspace-relative, like every `put` path):
printf 'def add(a, b):\n    return a + b\n' | mocactl sbx put experiments/e14-sbx/demo/calc.py

mocactl sbx pull --apply                      # bring the fix back to this tree
cd experiments/e14-sbx/demo && python3 -m unittest            # passes locally; git diff shows the one-line change
```

Starting `claude` for the first time in a fresh clone, it asks about the `sandbox` MCP
server that `up` wired up:

```
New MCP server found in this project: sandbox
```

Choose **"Use this MCP server"**. The highlighted default is *"Continue without using
this MCP server"*, and taking it writes `disabledMcpjsonServers: ["sandbox"]` into
`.claude/settings.local.json` — which, together with the local tools `up` denies in
`.claude/settings.json`, leaves the agent with no tools at all and no prompt on the next
run. To recover, delete `.claude/settings.local.json` and start `claude` again. Launch it
from the repository root, so it reads the `.mcp.json` and `.claude/settings.json` that
`up` wrote there.

What this walks through: `up`'s push and agent binding, per-`Exec` microVMs, the
client write path (`put`), the MCP path if you use an agent, and `pull --apply`'s
guarded apply. Internal code only, no secrets — the sandbox is shared
infrastructure.

The bug is the point: don't fix it before pushing.
