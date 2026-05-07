+++
disableToc = false
title = "Context Compression"
weight = 28
url = '/features/compression'
+++

LocalAI can transparently compress long chat conversations before they
exceed a model's context window. When enabled per model, an opt-in
middleware partitions the conversation into a "compress head" and a
"keep tail", asks a small compressor model to summarise the head, and
forwards the trimmed request to the primary model — all server-side,
without any client changes.

## When to enable

The feature is useful in three common scenarios:

1. **Long agent runs** that accumulate many tool-call turns and
   eventually push past `context_size`.
2. **Multi-turn assistants** where users keep typing into the same
   conversation rather than starting a new one.
3. **Tool-heavy MCP chains** whose intermediate tool results bloat the
   conversation faster than the user's actual messages.

When disabled (the default), LocalAI behaves exactly as it does today:
requests at or above `context_size` produce the usual context-overflow
error.

## Configuration

Compression is configured per model via the `compression:` block in the
model's YAML file. Absent the block — or with `enabled: false` — the
middleware is a no-op for that model.

```yaml
# models/qwen3-35b-apex.yaml
name: qwen3-35b-apex
context_size: 32768
parameters:
  model: Qwen3-35B-A3B-APEX-Q4_K_M.gguf

compression:
  enabled: true
  trigger_at_ratio: 0.75            # default 0.75 — fires when a request reaches 75% of context_size
  keep_tail_tokens: 8000            # default 8000 — never compress the final 8k tokens
  max_summary_tokens: 2048          # default 2048 — caps generated summary length
  compressor_model: LFM2-24B-A2B-GGUF   # optional — falls back to primary model
  on_post_compression_overflow: drop_oldest_summary   # "drop_oldest_summary" (default) | "error"
```

### Field reference

| Field | Type | Default | Description |
|---|---|---|---|
| `enabled` | bool | `false` | Master switch. Absence of this whole block is equivalent to `enabled: false`. |
| `trigger_at_ratio` | float (0,1] | `0.75` | Fraction of `context_size` at which compression fires. Token-based, recomputed per request. |
| `keep_tail_tokens` | int | `8000` | Minimum trailing tokens preserved verbatim. Token-based (not role-based) so tool-call chains with many short messages are handled correctly. |
| `max_summary_tokens` | int | `2048` | Hard cap on the generated summary's length. |
| `compressor_model` | string | `""` (= primary) | Model used to produce the summary. Should be small and fast (e.g. an MoE A3B). Falls back to the primary model when empty. |
| `on_post_compression_overflow` | string | `drop_oldest_summary` | Behaviour when the compressed request still exceeds `context_size`. Either drop the oldest synthetic summary and retry (default) or return HTTP 413 (`error`). |

### Compressor model requirements

The compressor model is invoked with empty `predInput` and the
conversation history as structured `messages`, so it must support
chat-template rendering. Set `use_jinja: true` on the compressor model
unless you know it has a custom Go-side template wired up. Any model
that already serves chat completions correctly will work as a
compressor.

## How it works

For each request that triggers, the middleware:

1. Counts request tokens using the in-process token counter (`pkg/tokens`,
   tiktoken-go-based).
2. Compares the count to `context_size * trigger_at_ratio`. Under
   threshold → request passes through unchanged.
3. Partitions messages back-to-front so the tail covers at least
   `keep_tail_tokens`. Everything before the partition is the
   compress-head.
4. Calls the compressor model with a fixed system prompt:
   > Summarize the following conversation for an AI agent to continue
   > coherently. Preserve: names, numbers, decisions, URLs, error
   > messages, tool names and their results. Drop: pleasantries,
   > repetition. Max: 500 tokens.
5. Replaces the compress-head with one synthetic system message
   containing `[COMPRESSED]: <summary>`.
6. If the resulting request still exceeds `context_size`, recovers by
   dropping the synthetic summary (when
   `on_post_compression_overflow: drop_oldest_summary`) or returns
   HTTP 413 (when `error`).
7. Forwards the transformed request to the primary model.

The middleware applies to both `/v1/chat/completions` and
`/v1/mcp/chat/completions`.

## Best-effort failure mode

Compression is treated as best-effort optimisation. If anything fails
along the way — encoding lookup, compressor-model error, summarizer
timeout — the middleware logs a warning and forwards the **original**
request unchanged. The user-visible behaviour is "compression silently
did not help" rather than "your chat broke".

## Backward compatibility

Compression is purely additive:

- Models without a `compression:` block see no behaviour change.
- Existing OpenAI-compatible clients are unaffected; no request or
  response shape changes for the standard fields.
- The middleware is registered on the same routes as today
  (`/v1/chat/completions`, `/v1/mcp/chat/completions`) but only acts
  when the model opts in.

## Limitations

- **Approximate counting for non-OpenAI models.** Token counts are
  exact for OpenAI-family encodings (`cl100k_base`, `o200k_base`) and
  approximate (within ~5%) for Qwen, Llama, Mistral, Anthropic, and
  Gemini models. Accurate enough for trigger thresholds; not suitable
  as billing-grade input.
- **Single-pass summarisation.** Recursive summarisation (summary of
  summaries) is intentionally out of scope; one pass covers the
  long-conversation cases that prompted the feature.
- **No cross-request memory.** Each request is compressed independently;
  summaries from prior turns are not persisted.
- **No automatic re-embedding** of compressed content into a knowledge
  collection.

## Recommended setup

1. Pick a small fast model as your compressor (a 3B–8B MoE works well —
   the goal is summary quality, not raw capability).
2. Make sure the compressor's YAML has `use_jinja: true`.
3. Enable compression on your primary chat model with the defaults.
4. Watch the logs for `compression applied` debug entries — they include
   the original/compressed token counts so you can verify the feature
   is doing what you expect.

## Troubleshooting

**Compression never fires.** Check the model's `context_size` is set
(otherwise the trigger threshold cannot be computed and the middleware
no-ops). Verify token counts in the logs at debug level.

**Compression fires but the compressor errors out.** The most common
cause is the compressor model lacking `use_jinja: true`. The chat
completion still succeeds because compression failures fall through to
passthrough; check for `compression failed; falling through to
passthrough` in the warning logs.

**Summary quality is poor.** Switch the compressor to a stronger model
or raise `max_summary_tokens`. Note that the prompt itself is fixed in
this release; per-model prompt overrides are a future enhancement.

**Request still hits context-overflow after compression.** Set a more
aggressive `trigger_at_ratio` (e.g. `0.6`) so compression fires earlier,
or reduce `keep_tail_tokens`. As a last resort,
`on_post_compression_overflow: error` makes the failure loud.
