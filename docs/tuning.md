# Tuning

Defaults are the measured best on an M4 Pro. Change one thing at a time and re-run
`scripts/benchmark.sh` — most knobs here trade against each other.

## Choosing a quantization

| target | RAM (weights + drafter) | baseline | with DFlash 2 |
|---|---|---|---|
| `mlx-community/Qwen3.8-27B-4bit` | ~18 GB | 15.1 tok/s | **40.6 tok/s** |
| `mlx-community/Qwen3.8-27B-8bit` | ~29 GB | 8.4 tok/s † | 30.5 tok/s † |

† upstream's figures, not measured here.

4-bit is the default: it is the faster machine in absolute terms and leaves room for a
large context. Take 8-bit only if you have ≥ 48 GB *and* you care more about output
quality than latency.

```bash
QWEN38_MODEL=mlx-community/Qwen3.8-27B-8bit qwen38-serve
```

## Context window

Set with `QWEN38_CTX` (default 131072). This model is cheap on context — only 16 of its
64 layers keep a KV cache — so the practical ceiling is higher than for a dense 27B.
Leave headroom: weights plus cache plus everything else you are running must fit in
unified memory, and macOS will swap rather than fail.

## Drafter mode

`auto` resolves DFlash 2 on ≥ 0.14.0 and is what you want. The others are for A/B:

```bash
QWEN38_MODE=baseline qwen38-serve   # no drafter — the honest denominator
QWEN38_MODE=dspark   qwen38-serve   # the other head, ~30% slower here
```

Speculative decoding is **lossless**: the target verifies every token, so the output is
identical to plain decoding. A bad drafter costs speed, never quality — which means you
can tune this aggressively without worrying about output drift.

## Sampling

Qwen3.8 ships two regimes and mixing them up is a real quality hit:

| | temperature | top_p | top_k |
|---|---|---|---|
| thinking (default) | 1.0 | 0.95 | 20 |
| non-thinking | 0.7 | 0.80 | 20 |

`config/qwen-settings.json` uses the thinking values, matching the server's
`--reasoning-effort medium`. If you switch the server to `--no-thinking`, switch the CLI
sampling params too.

## Reasoning effort

`--reasoning-effort {low,medium,high,xhigh}` on the launcher. `medium` is the default
here. `xhigh` measurably improves hard reasoning and measurably slows every turn — for a
coding agent that reads files and makes small edits, it mostly buys longer `<think>`
blocks you never read.

## What not to bother with

- `--kv-bits` — rejected on this model, see [pitfalls](pitfalls.md#4--kv-bits-is-rejected-on-this-model).
- Raising `--max-draft` — measured slower, see [pitfalls](pitfalls.md#5-a-wider-drafter-is-not-a-faster-drafter).
- `--wired-limit` / `sysctl iogpu.wired_limit_mb` — wired pages cannot be reclaimed, and
  on a shared 48 GB machine that risks starving everything else for a few percent.
