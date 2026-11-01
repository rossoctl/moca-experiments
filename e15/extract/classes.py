"""Command classes of SPEC §5.6.

A call's class comes from its tool name; for shell calls, from its first executable after shell
plumbing is skipped. When every executable is plumbing, the first one is used as is.
"""

TOOL_CLASSES = {
    "Read": "read",
    "Write": "write", "Edit": "write", "apply_patch": "write", "NotebookEdit": "write",
    "multiedit": "write",
    "Grep": "search", "Glob": "search", "LS": "search",
}

PLUMBING = frozenset(
    "cd echo true printf export set source test [ false : exit unset env timeout time nohup"
    " xargs tee".split())

_EXECUTABLES = {
    "test": "pytest",
    "interpreter": "python python3 python-script uv conda node bun deno uvicorn torchrun",
    "build": "cargo go make cmake gcc g++ javac mvn gradle tsc rustc dotnet npm npx pnpm yarn pip"
             " nvcc just",
    "lint_check": "ruff mypy eslint prettier py_compile jest vitest tox",
    "vcs": "git gh",
    "shell_read": "grep rg find cat head tail ls wc sed awk sort cut tr uniq diff stat file tree du"
                  " df jq less nl basename dirname realpath readlink which date seq pwd perl"
                  " sqlite3 pdftotext",
    "file_ops": "cp mv rm mkdir touch chmod ln tar unzip zip gzip mktemp",
    "wait": "sleep wait",
    "process": "ps pgrep pkill kill top lsof free uptime nproc ss tmux setsid flock",
    "host_infra": "docker podman kubectl oc helm nvidia-smi ssh sshpass scp rsync sudo systemctl"
                  " journalctl aws gcloud az terraform nsys ncu perf numactl",
    "network": "curl wget",
}
EXECUTABLE_CLASSES = {exe: cls for cls, names in _EXECUTABLES.items() for exe in names.split()}

CLASSES = ("read write search test interpreter build lint_check vcs shell_read file_ops wait"
           " process host_infra network opaque unparsed other").split()


def primary(executables):
    """The first non-plumbing executable, else the first one, else None."""
    if not executables:
        return None
    return next((e for e in executables if e not in PLUMBING), executables[0])


def classify(tool_name, executables):
    if tool_name in TOOL_CLASSES:
        return TOOL_CLASSES[tool_name]
    exe = primary(executables)
    if exe is None:
        return "unparsed"
    if exe.startswith("custom_"):
        return "opaque"
    return EXECUTABLE_CLASSES.get(exe, "other")
