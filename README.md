# Qwen3.8-27B locally, driving the Qwen Code CLI

A working recipe for running **Qwen3.8-27B** on Apple Silicon with speculative decoding,
and pointing the **Qwen Code** agent CLI at it. No cloud, no API key, no telemetry.

**40.6 tok/s on an M4 Pro** — 2.7× plain decoding — in ~18 GB.

```bash
git clone https://github.com/Remenby31/qwen-code-local-mlx
cd qwen-code-local-mlx && ./scripts/install.sh

cd ~/your-project && qw          # that's it
```

`qw` starts the model server if it isn't already running, waits for it, then hands you
the Qwen Code CLI. One terminal, no daemon to babysit.

| | |
|---|---|
| `qw [args…]` | run the CLI here, starting the server if needed |
| `qw status` | up? holding how much? is the cache warm? |
| `qw stop` | free the ~23 GB when you need it back |
| `qw restart`, `qw logs` | the obvious things |

```console
$ qw status
server   : up on :8080 (pid 94183), holding 23 GB
model    : Qwen3.8-27B-4bit
mode     : dflash  (drafter: incoai/Qwen3.8-27B-DFlash2)
cache    : on, warm — 5 hits, 95,779 tokens reused
accept   : 2.72 tokens/round over 6 requests
```

**There is deliberately no idle auto-stop.** The prefix cache lives in RAM and dies with
the server (its SSD spill is an overflow valve, not persistence), so a stop/start cycle
costs a minute of loading *plus* a cold first turn — roughly three minutes of real time.
A timer that reclaims memory you weren't short of is a bad trade. Stopping is a decision
you make.

---

## Why this is not just "run Ollama"

Qwen3.8-27B is a dense 27B model. On an M4 Pro it decodes at ~15 tok/s — technically
usable, practically not, because an agent CLI makes many turns per task.

The fix is **speculative decoding**: a small drafter proposes a block of tokens and the
27B model verifies them all in one forward pass. Decoding a dense model is bandwidth-bound
— you re-read 15 GB of weights per token — so verifying eight tokens costs barely more
than generating one. This repo uses [DFlash 2](https://inco.ai/blog/dflash2/), a
block-diffusion drafter that proposes a whole block in a single pass and walks a coherent
path through the candidates rather than picking each position independently.

It is **lossless**. The 27B model verifies every token, so the output is identical to what
plain decoding would produce. A weak drafter costs speed, never quality.

## Measured

Apple M4 Pro, 48 GB, macOS 26.5, mlx-dspark 0.14.0, `mlx-community/Qwen3.8-27B-4bit`,
greedy, 512 tokens. Reproduce with `scripts/benchmark.sh`.

| mode | tok/s | accepted tokens / round | vs baseline |
|---|---|---|---|
| baseline (no drafter) | 15.1 | — | 1× |
| DSpark | 31.0 | 4.35 | 2.05× |
| **DFlash 2** (default) | **40.6** | **5.49** | **2.69×** |

Sampled (temperature 1.0 / top-p 0.95 / top-k 20) instead of greedy: ~24 tok/s.

Decode speed is not what you feel, though. End to end through the Qwen Code CLI, on a
"find the bug in this function, fix it with the edit tool, tell me what you changed" task:

| | wall clock |
|---|---|
| first turn of a session (cold prefix cache) | 177 s |
| second turn, same project (warm) | **44 s** |

Prefill of the CLI's ~20k-token system prompt dominates everything else, which is why the
prefix cache matters more than any decoding knob — and why one-shot `-p` invocations feel
much worse than a session you keep open. See
[pitfalls #1](docs/pitfalls.md#1-on-agent-workloads-prefill-dominates--not-decode-throughput).

Your ratio will differ. It is measured against *your* baseline, so a faster machine
usually shows a *smaller* multiple — see
[pitfalls #8](docs/pitfalls.md#8-ratios-flatter-the-slower-baseline).

## Requirements

- Apple Silicon (M1 or later). MLX is Metal-only — there is no CUDA path here.
- **24 GB** unified memory minimum for the 4-bit target, 32 GB comfortable, 48 GB for 8-bit.
- ~20 GB free disk (weights are cached in `~/.cache/huggingface`).
- Node.js, for the Qwen Code CLI.
- Python 3.13 — the installer builds its own venv. **Not 3.14**: MLX has no wheels for it yet.

## What gets installed

| | |
|---|---|
| `~/.venvs/mlx-dspark` | isolated venv with [mlx-dspark](https://github.com/ARahim3/mlx-dspark) ≥ 0.14.0 |
| `~/.local/bin/qwen38-serve` | launcher — OpenAI-compatible server on `127.0.0.1:8080` |
| `~/.qwen/settings.json` | points the Qwen Code CLI at it (existing file is backed up, not overwritten) |
| `~/.cache/huggingface` | ~16 GB target + ~2 GB drafter, downloaded on first run |

Nothing is installed system-wide except the npm CLI. To remove everything: delete the venv,
the launcher, and the model cache.

## The model

[Qwen3.8-27B](https://huggingface.co/Qwen/Qwen3.8-27B) (Apache 2.0) is a dense 27B **hybrid
Gated DeltaNet** model — 64 layers alternating 3 linear-attention layers to 1 full-attention
layer. 262k context natively. Thinking mode on by default, switchable per request.

Two consequences of that architecture show up constantly in this setup:

- **Long context is cheap.** Only 16 of 64 layers keep a KV cache.
- **`--kv-bits` is rejected.** The recurrent-state layers are not KV caches and cannot be
  quantized as such.

The MLX conversion drops the vision encoder, so this is **text-only**. For image input,
serve the original checkpoint with vLLM or SGLang on a CUDA box.

## Using it

Any OpenAI-compatible client works — the server also speaks the Anthropic Messages API, so
Claude Code can point at it too.

```bash
curl localhost:8080/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"Qwen3.8-27B-4bit","messages":[{"role":"user","content":"Hi"}]}'
```

Tool calling works, which is what makes the agent CLI usable at all:

```bash
curl -s localhost:8080/metrics | python3 -m json.tool   # accept length, cache hits, throughput
```

## Read these before tuning

- **[docs/pitfalls.md](docs/pitfalls.md)** — eight traps, all hit and measured while building
  this. The first one (prefill dominates decode on agent workloads) is worth more than
  every other optimization here combined.
- **[docs/tuning.md](docs/tuning.md)** — quantization, context, sampling, and the knobs that
  are not worth touching.

## Credits

The heavy lifting is other people's:
[mlx-dspark](https://github.com/ARahim3/mlx-dspark) (the MLX speculative-decoding engine),
[z-lab/dflash](https://github.com/z-lab/dflash) and [Inco AI](https://inco.ai/blog/dflash2/)
(DFlash / DFlash 2), [MLX](https://github.com/ml-explore/mlx), the
[Qwen team](https://qwen.ai), and [Qwen Code](https://github.com/QwenLM/qwen-code).

This repo is the glue, the measurements, and the list of things that went wrong.

MIT.
