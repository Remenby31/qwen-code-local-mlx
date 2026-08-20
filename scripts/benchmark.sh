#!/usr/bin/env bash
# Reproduce the numbers in the README on your own machine.
# Usage: scripts/benchmark.sh [model-repo]   (default: the 4-bit target)
set -euo pipefail
VENV="${QWEN38_VENV:-$HOME/.venvs/mlx-dspark}"
MODEL="${1:-mlx-community/Qwen3.8-27B-4bit}"
TOKENS="${BENCH_TOKENS:-512}"
PROMPT="Write an LRU cache in Python with docstrings and three unit tests."

printf '%-26s %s\n' "model:" "$MODEL"
printf '%-26s %s\n' "machine:" "$(sysctl -n machdep.cpu.brand_string), $(( $(sysctl -n hw.memsize) / 1073741824 )) GB"
printf '%-26s %s\n\n' "mlx-dspark:" "$("$VENV/bin/python" -c 'import importlib.metadata as m;print(m.version("mlx-dspark"))')"

for mode in baseline dspark dflash; do
  out=$("$VENV/bin/mlx-dspark" generate --model "$MODEL" --mode "$mode" \
        --temperature 0 --max-new-tokens "$TOKENS" --no-stream --prompt "$PROMPT" 2>&1 \
        | sed $'s/\x1b\\[[0-9;]*m//g' | grep -E 'tok/s' | tail -1) || out="(failed)"
  printf '%-10s %s\n' "$mode" "$(echo "$out" | sed 's/^ *//')"
done
