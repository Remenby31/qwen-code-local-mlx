# Pitfalls

Everything here was hit and measured on an M4 Pro / 48 GB while building this setup. Each
entry costs real time to rediscover.

## 1. On agent workloads, prefill dominates — not decode throughput

The most expensive mistake available here. A coding CLI resends its whole system prompt
(~20k tokens for Qwen Code) every single turn, so what you feel is prefill, not tok/s.

Measured on the same one-line edit task ("fix this function, then tell me what you
changed"), same model, same machine:

| | decode | wall clock |
|---|---|---|
| prefix cache **off** | 37.9 tok/s | **658 s** |
| prefix cache **on**, cold (first turn of a session) | 40.6 tok/s | 177 s |
| prefix cache **on**, warm (second turn, same project) | 40.6 tok/s | **44 s** |

The uncached run decoded *faster* and finished 15× slower. Note also that the win only
lands from the second turn: the first turn of any session pays full prefill, so short
one-shot invocations never see it — keep a session open.

Always confirm the cache is live before tuning anything else:

```bash
curl -s localhost:8080/metrics | python3 -c 'import sys,json;print(json.load(sys.stdin)["prefix_cache"])'
# {'enabled': True, 'mode': 'checkpoint', ..., 'l2': True}
```

(Older mlx-dspark disabled the prefix cache in `dflash` mode; ≥ 0.14.0 covers it. This is
the main reason the installer enforces a minimum version.)

## 2. Verify a version before diagnosing a "missing feature"

A missing entry in `mlx-dspark models` reads like *not supported yet*. Usually it means
*your install is old*. Check what upstream actually ships before concluding anything:

```bash
$VENV/bin/python -c 'import importlib.metadata as m; print(m.version("mlx-dspark"))'
```

If your environment proxies PyPI, `pip install -U` may not see recent releases and will
leave you on an old version without saying so. Install from a git clone in that case.

## 3. There are two `Qwen3.8-27B-DFlash2` repos

`incoai/Qwen3.8-27B-DFlash2` is the one mlx-dspark loads and the one its registry
resolves. The `z-lab/` repo of the same name has a different tensor layout and fails with:

```
ValueError: tensor names don't match a z-lab DFlash drafter.
  unexpected in checkpoint (23): ['candidate_selector.hidden_projection.weight', ...]
```

Just leave `--mode auto` and let the registry choose.

## 4. `--kv-bits` is rejected on this model

Qwen3.8 is a hybrid Gated DeltaNet: only 16 of its 64 layers hold a real KV cache, the
rest carry recurrent state that is not a KV cache and cannot be quantized as one.

The upside is bigger than the restriction: long context is unusually cheap here, because
three quarters of the layers never grow a KV cache at all.

## 5. A wider drafter is not a faster drafter

Verification cost on Apple Silicon grows linearly with verify width, so acceptance and
throughput pull in opposite directions. Measured (DSpark, 4-bit):

| cap | tok/s | accept |
|---|---|---|
| 7 (default) | 22.9 | 3.37 |
| auto | 20.1 | 2.36 |
| **15** | **10.3** | 3.27 |

`cap 15` bought acceptance and halved throughput. Leave the cap alone unless you measure.

## 6. Python 3.14 has no MLX wheels

MLX lags the newest CPython by months. If `python3` is a fresh Homebrew 3.14, a venv built
from it resolves no mlx build. Pin 3.13 (the installer does).

## 7. The Qwen CLI needs `security.auth.selectedType`

Environment variables (`OPENAI_BASE_URL` etc.) work interactively, so a config that is
missing this key can look fine — then headless `-p` runs die with:

```
No auth type is selected. Please configure an auth type before running in non-interactive mode.
```

The shipped `config/qwen-settings.json` sets it.

## 8. Ratios flatter the slower baseline

Published speedups are quoted against whatever baseline the author ran. The 8-bit target
is more memory-bound, so speculation lifts it further *in ratio* while landing lower *in
absolute* throughput:

| | baseline | with DFlash 2 | ratio |
|---|---|---|---|
| 8-bit (upstream's figure) | 8.4 tok/s | 30.5 tok/s | **3.63×** |
| 4-bit (this repo) | 15.1 tok/s | **40.6 tok/s** | 2.69× |

Compare absolute numbers. The smaller multiple is the faster machine.
