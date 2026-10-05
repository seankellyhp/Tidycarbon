# Plan: provider-side inference impacts and token accounting

Status: steps 1-3 and 5 implemented on branch `external_models`
(`inst/python/tidycarbon_provider.py`, `R/provider.R`, tracker hooks,
`tests/testthat/test-provider.R`). Step 4 is open. Decisions taken: reuse the
Python module; support both ellmer and Claude Code transcripts; keep provider
results separate from the CodeCarbon figures (`provider` list-column on
`carbon_track()`, `$provider` on `carbon_run()`, `provider_log` attribute on
`carbon_step()`). In the hooks, each request's latency is capped at the
tracked block's wall time, which is a true upper bound.

CodeCarbon measures the electricity *this machine* draws. When R code calls a
hosted LLM, the inference runs in the provider's datacenter, where CodeCarbon
cannot see it. This plan adds a second, clearly separate block of figures to
tidycarbon: the billed token usage of those calls and an EcoLogits estimate of
the provider-side impact. The design follows the `/carbon` Claude Code skill
(`~/.claude/skills/carbon/scripts/tokens.py` and `provider_impacts.py`).

## How the `/carbon` skill does it

### Tokens (`tokens.py`)

- No tokenizer. It reads the `usage` object the harness already writes to its
  session transcript, i.e. the counts the provider actually billed.
- One `Call` per billed request: `ts`, `model`, `fresh` (uncached input),
  `cache_read`, `cache_write`, `output`, `thinking`, `sidechain` (subagent),
  `latency`.
- Claude Code writes the same message once per content block, so rows are
  deduplicated on `message.id`. Latency is the time from the `parentUuid`
  record (the triggering user message or tool result) to the message's last
  line. It is approximate, but it is only ever used as an upper bound.
- `load()` is the single place usage is read. The Tokens section and the
  provider estimate are built from the same list of requests, so they cannot
  disagree.

### Provider estimate (`provider_impacts.py`)

1. `split_model()` turns whatever model string was recorded into
   `(provider, bare model)`. It handles `claude-opus-5`,
   `anthropic/claude-sonnet-4-5`, `openrouter/anthropic/...` and Bedrock ids
   such as `us.anthropic.claude-opus-4-1-20250805-v1:0`.
2. `resolve()` matches the model against the EcoLogits registry. The match is
   one of:
   - `exact`;
   - `exact, provider inferred`: a bare name that only one provider claims;
   - `proxy: nearest registered <family>`: the nearest lower registered
     version of the same family, for models newer than the EcoLogits release;
   - `unregistered` / `no provider`: the request is reported as
     `NOT MODELLED` and left out of the totals.
3. `llm_impacts(provider, model, output_token_count, request_latency, zone)`
   runs **once per request**, never on session totals. The model is not
   linear in model, output length or latency, so the sum of per-request
   estimates differs from one estimate over the totals. A missing latency is
   passed as `Inf`.
4. Totals are summed separately at the lower and upper ends of each range,
   which is deliberately conservative. Impacts reported: energy (kWh), GWP
   (kg CO2e), water (L), primary energy (MJ) and ADPe, abiotic
   (mineral) resource depletion (kg Sb eq).
5. Each provider's inference is charged to its own datacenter grid, as
   EcoLogits records it. `CARBON_ECOLOGITS_ZONE` can force one zone.

### Caveats the skill enforces

- **Only output tokens and latency enter the model.** Input and cache tokens
  contribute nothing, so the estimate prices output generation, not "the
  impact of the session".
- **Figures are ranges** whenever the provider does not publish its model's
  architecture. A provider that publishes it gets a single value.
- **Latency can only lower the estimate.** A latency that is too long changes
  nothing; one that is too short truncates the estimate.
- **Stand-in (proxy) matches are named** on every line they affect.
- **Never add provider figures to CodeCarbon's**, and never compute
  "Wh per token" from local energy. They have different scopes and different
  methods.

## Plan for tidycarbon

### 1. Python core, reused through reticulate

- Create `inst/python/tidycarbon_provider.py` with `split_model`, `resolve`,
  `estimate`, `total`, and the Claude Code transcript reader, copied nearly
  verbatim from the skill.
- Load it with `reticulate::import_from_path()` and
  `reticulate::py_require("ecologits")`. Only the provider functions load it,
  so plain CodeCarbon users are unaffected.
- Rationale: EcoLogits is Python-only anyway. Porting the model-resolution
  logic to R would only duplicate it and let it drift from the skill.

### 2. New `R/provider.R`, built around one standard table of requests

One row per billed request:

| column          | type   | notes                                       |
|-----------------|--------|---------------------------------------------|
| `ts`            | POSIXct| `NA` when the client does not record it     |
| `provider`      | chr    | may be `""`; `split_model()` fills it in    |
| `model`         | chr    | as the client recorded it                   |
| `input_tokens`  | int    | uncached input                              |
| `cache_read`    | int    | `0` when unknown                            |
| `cache_write`   | int    | `0` when unknown                            |
| `output_tokens` | int    | the only token count EcoLogits uses         |
| `latency_s`     | dbl    | `NA` when unknown, sent to EcoLogits as `Inf` |

Ways to get that table:

- `calls_from_ellmer(chat, since = 0)`: turns come from `chat$get_turns()`
  (each assistant turn's `@tokens`), and the model from
  `chat$get_provider()@model`. In ellmer 0.2.1, `@tokens` is only
  `c(input, output)`, with no timestamp, latency or cache counts. So
  `latency_s` is `NA` and the cache columns are `0`. The docs must say so.
- `calls_from_transcript(path, start, end)`: the Claude Code reader, for
  tracking agent sessions.
- A plain tibble in the schema above, for rollama, httr2 or any other client.

Functions built on it:

- `carbon_tokens(calls)` returns a one-row summary: calls, sent, received,
  total, cache hit %, average context per call.
- `carbon_provider(calls, zone = NULL)` returns one row per request:
  - `provider, model, resolved_model, resolution, modelled, output_tokens, latency_s`
  - `energy_kwh_min/max, gwp_kg_min/max, water_l_min/max, pe_mj_min/max,
    adpe_kgsb_min/max`
  - When EcoLogits gives a single value, `min == max`.
- `carbon_provider_summary(x)` returns totals summed separately at the lower
  and upper ends, a per-model breakdown (calls, output tokens, resolution),
  and the number of requests and output tokens left out as `NOT MODELLED`.

### 3. Hooking it into the existing trackers

- Add an optional `chat = NULL` argument to `carbon_track()`, `carbon_run()`
  and `carbon_step()`.
- They record `length(chat$get_turns())` before running the code, then take
  only the new turns afterwards and pass them to
  `calls_from_ellmer(chat, since = n)`.
- The provider result goes into a separate `provider_log` attribute
  (alongside `carbon_log`), or into columns prefixed `provider_`. The existing
  CodeCarbon columns stay unchanged, and nothing adds the two scopes together.

### 4. Later phases

- A "Provider inference" tab in `inst/app/app.R`.
- A `provider_*` metric for `autoplot.carbonbench()`.
- Optionally write `provider_impacts.csv` next to `emissions.csv`.
- `DESCRIPTION`: add `ellmer` to `Suggests`. `ecologits` is required
  lazily through `py_require()`.
- A README section explaining the two scopes and the caveats above.

### 5. Tests

- `split_model()` with every spelling in the skill's docstring, including
  `gpt-3.5-turbo`, which must survive intact.
- `resolve()` proxy: `claude-opus-5` maps to the nearest registered Opus.
- An ellmer fixture built with `ellmer::Turn("assistant", ..., tokens = c(10, 5))`,
  so no API call is needed.
- Separate lower/upper summing over a mix of ranges and single values.
- An unmatched model: counted as `NOT MODELLED` and excluded from the totals.

## Open decisions

1. **Port to R or reuse Python?** Recommended: reuse the Python module
   (step 1).
2. **Main source of requests:** ellmer chats (R users calling LLMs), Claude
   Code transcripts (agent sessions), or both.
3. **Output shape:** provider columns on the existing tibble, or a separate
   attribute or table. Leaning towards separate, so the two scopes cannot be
   added together by accident.
