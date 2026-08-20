#!/usr/bin/env bash
# One-shot setup: venv + mlx-dspark + Qwen Code CLI + launcher + CLI config.
# Idempotent — safe to re-run. Nothing is installed system-wide except the npm CLI.
set -euo pipefail

VENV="${QWEN38_VENV:-$HOME/.venvs/mlx-dspark}"
BIN_DIR="${QWEN38_BIN_DIR:-$HOME/.local/bin}"
MIN_VERSION="0.14.0"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
die() { printf '\033[31merror: %s\033[0m\n' "$1" >&2; exit 1; }

# --- preflight ---------------------------------------------------------------
[[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]] \
  || die "Apple Silicon only (MLX has no CUDA/x86 backend)."

RAM_GB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
(( RAM_GB >= 24 )) || die "Need >= 24 GB unified memory for the 4-bit target (found ${RAM_GB} GB)."
(( RAM_GB >= 32 )) || echo "note: ${RAM_GB} GB works, but keep the context modest (see README)."

command -v node >/dev/null || die "node is required for the Qwen Code CLI (brew install node)."

# --- python venv -------------------------------------------------------------
# 3.13, not 'whatever python3 is': MLX wheels lag the newest CPython by months, and a
# 3.14 default silently resolves to no mlx build at all.
say "Python 3.13 venv at $VENV"
if command -v uv >/dev/null; then
  uv venv --python 3.13 "$VENV"
else
  command -v python3.13 >/dev/null || die "install uv (recommended) or python3.13"
  python3.13 -m venv "$VENV"
fi

say "Installing mlx-dspark (>= $MIN_VERSION)"
if command -v uv >/dev/null; then
  VIRTUAL_ENV="$VENV" uv pip install -U "mlx-dspark>=$MIN_VERSION"
else
  "$VENV/bin/pip" install -qU "mlx-dspark>=$MIN_VERSION"
fi

GOT=$("$VENV/bin/python" -c 'import importlib.metadata as m; print(m.version("mlx-dspark"))')
# Below 0.14.0 the registry has no DFlash 2 entry for Qwen3.8-27B and quietly serves the
# slower DSpark head instead — the single most likely reason to not reproduce the README.
[[ "$(printf '%s\n%s\n' "$MIN_VERSION" "$GOT" | sort -V | head -1)" == "$MIN_VERSION" ]] \
  || die "mlx-dspark $GOT installed but >= $MIN_VERSION is required. If your environment
       proxies PyPI and cannot see recent releases, install from a git clone instead:
         git clone https://github.com/ARahim3/mlx-dspark /tmp/mlx-dspark
         VIRTUAL_ENV=$VENV uv pip install --no-deps /tmp/mlx-dspark"
echo "mlx-dspark $GOT"

# --- qwen code cli -----------------------------------------------------------
say "Qwen Code CLI"
if command -v qwen >/dev/null; then echo "already present: $(qwen --version)"
else npm install -g @qwen-code/qwen-code && echo "installed: $(qwen --version)"; fi

# --- launcher + config -------------------------------------------------------
say "Launcher -> $BIN_DIR/qwen38-serve"
mkdir -p "$BIN_DIR" && install -m 0755 "$REPO_DIR/bin/qwen38-serve" "$BIN_DIR/qwen38-serve"
case ":$PATH:" in *":$BIN_DIR:"*) ;; *) echo "note: add $BIN_DIR to your PATH." ;; esac

say "Qwen CLI config -> ~/.qwen/settings.json"
mkdir -p "$HOME/.qwen"
if [[ -e "$HOME/.qwen/settings.json" ]]; then
  cp "$HOME/.qwen/settings.json" "$HOME/.qwen/settings.json.bak.$(date +%s)"
  echo "existing config backed up; merge these keys in by hand:"
  sed 's/^/    /' "$REPO_DIR/config/qwen-settings.json"
else
  cp "$REPO_DIR/config/qwen-settings.json" "$HOME/.qwen/settings.json"
  echo "written"
fi

cat <<EOF

Done. Next:

  qwen38-serve                     # first run downloads ~16 GB, then loads for ~1 min
  qwen --model Qwen3.8-27B-4bit    # in another shell

Reproduce the benchmarks:  $REPO_DIR/scripts/benchmark.sh
EOF
