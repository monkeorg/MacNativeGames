#!/usr/bin/env bash
# Linux project tools only. Invoke with bash; never changes the managed image.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: bash .codex/setup.sh [-- command [arguments...]]

Without arguments, create/reuse the project virtual environment and install
the pinned runtime requirements plus CMake and Ninja. No tests or builds run.
With --, run a command in an existing matching environment without installing.
Set MACNATIVEGAMES_ENV to an absolute path to override games/totk/.venv.
EOF
}

fail() { printf '%s\n' "$*" >&2; exit 1; }

if [[ ${1:-} == --help ]]; then
    usage
    exit 0
fi
command_mode=false
if [[ $# -gt 0 ]]; then
    [[ $1 == -- && $# -gt 1 ]] || { usage >&2; exit 2; }
    command_mode=true
    shift
fi

[[ $(uname -s) == Linux ]] || fail 'This helper supports Linux only; use the documented Mac build setup on macOS.'
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
project_env=${MACNATIVEGAMES_ENV:-$repo_root/games/totk/.venv}
[[ $project_env == /* ]] || fail 'MACNATIVEGAMES_ENV must be an absolute path.'
requirements=$repo_root/games/totk/requirements.txt
[[ -f $requirements ]] || fail 'The checkout is missing games/totk/requirements.txt.'

check_environment() {
    [[ -f $project_env/pyvenv.cfg && -x $project_env/bin/python ]] ||
        fail 'Existing path is not a usable virtual environment; choose a new MACNATIVEGAMES_ENV path. Nothing was removed.'
    # Isolated interpreter startup ignores external Python import paths. Refuse
    # system-site access so installs cannot spill into another Python environment.
    "$project_env/bin/python" -I - "$project_env/pyvenv.cfg" <<'PY'
import pathlib
import sys

if sys.version_info[:3] != (3, 14, 8) or sys.prefix == sys.base_prefix:
    raise SystemExit('A Python 3.14.8 virtual environment is required; choose a new path. Nothing was removed.')
settings = dict(line.split('=', 1) for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if '=' in line)
settings = {key.strip().lower(): value.strip().lower() for key, value in settings.items()}
if settings.get('include-system-site-packages') != 'false':
    raise SystemExit('The virtual environment must disable system site packages. Nothing was changed.')
PY
}

if [[ -e $project_env || -L $project_env ]]; then
    check_environment
elif $command_mode; then
    fail 'Project environment is missing; run this helper without a command first.'
else
    command -v uv >/dev/null 2>&1 || fail 'The selected Linux image must provide uv; this helper does not install system tools.'
    uv python install 3.14.8
    uv venv --python 3.14.8 -- "$project_env"
    check_environment
fi

if $command_mode; then
    export VIRTUAL_ENV="$project_env"
    export PATH="$project_env/bin:$PATH"
    exec "$@"
fi

command -v uv >/dev/null 2>&1 || fail 'The selected Linux image must provide uv; this helper does not install system tools.'
uv pip install --python "$project_env/bin/python" -r "$requirements" \
    'cmake==3.31.10' 'ninja==1.13.2'
printf 'Project environment ready: %s\n' "$project_env"
printf 'No tests, probes, simulator, app build or device operations were run.\n'
