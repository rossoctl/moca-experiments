# E14 runbook — replicating the experiment

How to rebuild what [`EXPERIMENTS.md`](EXPERIMENTS.md) measured, from a bare KVM host to a graded
comparison. Every script and config named here is in [`HARNESS.md`](HARNESS.md), as run plus the
post-review fixes it lists. Copy each to the path in its heading, then substitute the variables
listed at the top of that file.

**One part of the experiment is left out on purpose:** the AWS rig of rounds 1–2's MCP path, which
was a P6 host with a systemd drop-in, a transitional setup.

The bare-metal standalone backend below covers everything round 3 needs, and round 1–2's gRPC
path. Round 1's toy repos are rebuilt by `sbx-toy-repos.sh` (`HARNESS.md` §4).

---

## 0. What you need

**The KVM host (the "rig"):**
- bare metal, or nested virtualization;
- `/dev/kvm`, cgroups v2, no swap, at least 24 GiB RAM for the shipped worker budget;
- sudo, and internet access for the build steps;
- Go ≥ 1.26 on root's `PATH`;
- Node 22 and podman;
- Firecracker and the jailer v1.17.0 at `/usr/local/bin/{firecracker,jailer}`;
- `grpcurl`, optional, for phase 4.

**The main repo** (`rossoctl/moca` and forks), with:
- `feat/relay-client-tokens` (`pdettori/moca`, commit `467b874`): the relay with client tokens,
  `docs/api/sandbox-v1-direct-client.md` and `docs/api/examples/sandbox_v1_client.py`;
- `upstream/main`'s `deploy/microvm/build-rootfs.sh`. It is not on that branch and doesn't depend on
  the version.

**The laptop:**
- Claude Code (tested 2.1.286) and OpenCode (`npx opencode-ai`, tested 1.18.35);
- Python ≥ 3.10 for the client tools, plus `uv`, to install Python 3.9 for the stock runs;
- an Anthropic-compatible model endpoint (`LITELLM_BASE_URL`, `LITELLM_KEY`). The runs used
  `aws/claude-sonnet-5-5` through LiteLLM.

**Safety, if the host already runs a P6 install:**
- The backend below shares nothing with it.
- Do **not** run `setup-microvm.sh` on such a host: it would put the host's P6 into tiered mode.
- On first start, the worker sweeps orphaned VM cgroups under `microvm.slice/microvm-vms.slice`. On a
  host with experiment leftovers that deletes them, so check `pgrep firecracker` first.

---

## 1. The sandbox backend on the rig

Prepare the two inputs on the laptop, then copy them over:

```bash
cd $MOCA && git bundle create /tmp/sbx-backend.bundle feat/relay-client-tokens
git -C <main-repo-at-upstream-main> show upstream/main:deploy/microvm/build-rootfs.sh > /tmp/build-rootfs.sh
scp /tmp/sbx-backend.bundle /tmp/build-rootfs.sh <the four phase scripts> $RIG:/tmp/
```

Then, on the rig, run in order (each script is in `HARNESS.md` §1):

| Phase | Script | Result |
| --- | --- | --- |
| 1 | `sbx-setup-1-code.sh` | `/opt/sbx-backend` (the branch, pi-fork built, deps installed); `/usr/local/bin/sbx-microvm-worker` |
| 2 | `sbx-setup-2-snapshot.sh` | Firecracker CI kernel, rootfs from `moca-remote-worker:latest`, golden snapshot at `/srv/sbx/snapshots/default` |
| 3 | `sbx-setup-3-services.sh` | `sbx-redis` (`127.0.0.1:6390`), `sbx-relay` (attach `:9543`, exec `127.0.0.1:9544`), `sbx-microvm-worker` (`moca_microvm_0`), fresh tokens, the client token in `~/sbx-exec-client.token` |
| 4 | `sbx-setup-4-verify.sh` | a cold and three warm Execs, workspace persistence, and the refusals |

Expected from phase 4:
- the cold first Exec takes about 200 ms, warm ones 70–90 ms on bare metal;
- `marker` persists into the next call;
- the key outside the prefix gets `PermissionDenied`;
- a random token gets `Unauthenticated`.

**For round 3, add to the rig** (`HARNESS.md` §1):
- `sbx-swe-snapshot.sh` bakes `mpmath asgiref typing_extensions sqlparse pytz tzdata` into the
  rootfs, rebuilds the snapshot, and swaps it in (the previous one is kept as `default-v1`);
- `sbx-swe-pth.sh` adds `workspace.pth`, so `/workspace` is importable like an editable install.

**Every change is appended to `~/sbx-backend-manifest.md` on the rig. To undo all of it:**
1. Disable and stop `sbx-relay` and `sbx-microvm-worker`.
2. Delete their unit files and `microvm-vms.slice`.
3. Run `podman rm -f sbx-redis`.
4. Delete `/opt/sbx-backend`, `/etc/sbx-backend`, `/srv/sbx` and `/usr/local/bin/sbx-microvm-worker`.

---

## 2. The client on the laptop

```bash
# gRPC stubs and a venv for the client tools
python3 -m venv /tmp/sbx-venv && /tmp/sbx-venv/bin/pip install grpcio grpcio-tools pandas pyarrow
mkdir -p /tmp/sbx-py && /tmp/sbx-venv/bin/python -m grpc_tools.protoc -I $MOCA/proto \
  --python_out=/tmp/sbx-py --grpc_python_out=/tmp/sbx-py sandbox/v1/sandbox.proto
# sbx.py goes next to sandbox_v1_client.py; the wrapper goes to /tmp/sbx-bin/sbx (HARNESS.md §2)

# the token, and the tunnel to the relay's exec port
scp $RIG:sbx-exec-client.token /tmp/sbx-exec.token && chmod 600 /tmp/sbx-exec.token
ssh -f -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -J $JUMP -L 9444:localhost:9544 $RIG

# smoke
export PATH=/tmp/sbx-bin:$PATH SBX_ADDR=localhost:9444 SBX_SANDBOX_ID=moca_microvm_0 \
       SBX_TOKEN_FILE=/tmp/sbx-exec.token SBX_WORKSPACE_KEY=sbx-exec-smoke
sbx run 'uname -r; python3 --version; git --version'
```

**Agent configs** (`HARNESS.md` §2):
- `/tmp/sbx-grpc-cfg/{AGENTS.md,CLAUDE.md,opencode.json}`;
- the OpenCode provider file at `/tmp/sbx-oc-provider.json` (set its `baseURL`).

Claude Code takes its restrictions as flags (shown in `HARNESS.md` §2), because a project settings
file's `allow` list is ignored until the folder is trusted interactively.

**Before any batch, check the gateway.** Both the gateway and the tunnel can depend on a VPN.

```bash
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $LITELLM_KEY" "$LITELLM_BASE_URL/v1/models"   # 200
```

---

## 3. Rounds 1–2 (optional)

- **Round 1:** `bash /tmp/sbx-toy-repos.sh` creates `/tmp/sbx-demo-repo` (`calc`) and `/tmp/sbx-demo2`
  (`inventory`). Then run `sbx-grpc-run.sh <cc|oc> <repo> <name> "<prompt>"` for each task and
  agent, with the T1/T2 prompts from `EXPERIMENTS.md` §3.
- **Round 2:**
  1. `git clone --depth 1 --branch 3.7 https://github.com/Python-Markdown/markdown /tmp/sbx-markdown`.
  2. Commit `importlib_metadata.py` (`HARNESS.md` §4) at the repo root.
  3. Save the round-2 prompt (`HARNESS.md` §4) as `/tmp/sbx-t3-prompt.txt`, then run
     `sbx-grpc-run.sh <cc|oc> /tmp/sbx-markdown <name> "$(cat /tmp/sbx-t3-prompt.txt)"`.
  4. Grade with `sbx-grpc-eval.sh <name>`, after `sbx-grpc-eval.sh baseline`, which should print
     `Ran 951 tests … FAILED (failures=8, errors=1, skipped=74)`.
  5. Summarize with `sbx-grpc-compare.py <names…>`.
- **The MCP path:** run the `packages/sandbox-mcp` server next to a relay (`HARNESS.md` §3) and use
  `sbx-run.sh` (`HARNESS.md` §4) instead. The server needs `SH_RELAY_ADDR`, `MOCA_RELAY_EXEC_TOKEN` (or a client
  token), `SBX_SANDBOX_ID` and `SBX_WORKSPACE_KEY`. It listens on `127.0.0.1:8787` only.

---

## 4. Round 3 — SWE-bench Verified subset

All scripts go in `/tmp/swe/` (`HARNESS.md` §5).

```bash
mkdir -p /tmp/swe && cd /tmp/swe
curl -sSL -o verified.parquet https://huggingface.co/datasets/princeton-nlp/SWE-bench_Verified/resolve/main/data/test-00000-of-00001.parquet
git clone -q --filter=blob:none --no-checkout https://github.com/sympy/sympy.git sympy.git
git clone -q --filter=blob:none --no-checkout https://github.com/django/django.git django.git

/tmp/sbx-venv/bin/python select_instances.py   # 18 candidates -> candidates.jsonl
/tmp/sbx-venv/bin/python prep.py               # per instance: history-free tree, issue, gold/test patch, meta
/tmp/sbx-venv/bin/python verify.py             # gold must resolve, base must fail FAIL_TO_PASS
```

**Expected from `verify.py`:**
- 16 `OK`;
- 2 `BAD`, `django-13658` and `django-16315`.

`final.txt` lists the 10 that the seeded order then picks:
- the first 2 "<15 min" and first 3 "15 min – 1 h" `OK` instances per project, in the order
  `select_instances.py` prints them.

**The local environment for the stock runs:**

```bash
uv python install 3.9 && uv venv -p 3.9 /tmp/swe/venv
VIRTUAL_ENV=/tmp/swe/venv uv pip install mpmath==1.3.0 asgiref==3.7.2 typing_extensions==4.12.2 \
  sqlparse==0.4.4 pytz==2024.1 tzdata==2024.1
```

**Run and score:**

```bash
/tmp/swe/run.sh sympy__sympy-19637 cc sbx      # one run, to check the wiring
/tmp/swe/batch.sh > /tmp/swe/batch.log 2>&1    # all 40: each issue's 4 variants concurrently; waits out
                                               # outages; reruns once any run an outage invalidated
/tmp/sbx-venv/bin/python /tmp/swe/report.py    # grades every run (cached), prints the tables
```

**Per run, `run.sh` writes `/tmp/swe/runs/<agent>-<mode>-<issue>/`**, containing:
- `agent.log`, the agent's JSON stream;
- `patch`;
- `calls.jsonl`, sandbox calls, remote mode only;
- `result.json`, the exit code and wall clock;
- `grade.json`, written by `report.py`.

A full batch took about 80 minutes of run time with a healthy gateway.

**Notes:**
- **Stock runs execute agent commands on your machine, unprompted.** Claude Code runs in
  `bypassPermissions` and OpenCode with `"*": "allow"`, in scratch checkouts under `/tmp/swe/runs/`,
  with web tools denied. In remote mode the shell allow-list is the only boundary
  (`EXPERIMENTS.md` §7).
- **The grader always runs in the sandbox**, so stock and remote patches are scored in the same
  environment.
- **Workspace keys** are `sbx-exec-r-<run>` (agent runs) and `sbx-exec-g-<label>-<issue>`
  (grading). The worker reclaims them after `SH_WORKSPACE_IDLE` (8 h).
- **Comparing modes on wall clock** only works within a batch; gateway latency varies a lot.
