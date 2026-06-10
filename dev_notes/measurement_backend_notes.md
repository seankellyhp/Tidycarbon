# Measurement Backend Notes: CSV as artifact, not dependency

Context for how `carbon_step()` / `carbon_run()` measure emissions and why the
`emissions.csv` file is written the way it is. Captures empirically-verified
CodeCarbon behavior (version 3.2.8, the one `reticulate::py_require()` resolves
at time of writing) so the design rationale isn't lost.

## The change that prompted this

`carbon_step()` / `carbon_run()` used to wrap code in `tracker$start()` /
`tracker$stop()` (the **session API**) and then re-read the new tail row of
`emissions.csv` to recover the per-step metrics. That read-back was lossy and
race-prone. It was replaced by the **task API** (`tracker$start_task()` /
`tracker$stop_task()`), which returns the rich emissions object in-memory, and
the CSV was demoted to a write-only artifact produced by
`R/measure.R::carbon_write_artifact()`. The shared core is
`R/measure.R::carbon_measure()`.

The CSV write is deliberately **not load-bearing**: it is wrapped in
`tryCatch`, failures are swallowed, and a skipped/failed write never affects the
returned result or the in-memory log (`carbon_collect()`). All emissions data
comes from `stop_task()` in memory.

## Verified CodeCarbon behavior (3.2.8)

| API | rich data in-memory? | writes `emissions.csv`? |
|-----|----------------------|--------------------------|
| **Session** `start()` / `stop()` | `stop()` returns a **scalar only** (kgCO2e); but the tracker stashes the full object on `tracker$final_emissions_data` after `stop()` | **Yes** — full ~38-column row, written by CodeCarbon |
| **Task** `start_task()` / `stop_task()` | **Yes** — `stop_task()` returns the full `EmissionsData` object | **No** — writes nothing to disk |

Both probes confirmed: the session tracker writes the CSV itself; the task
tracker writes nothing (`did CodeCarbon write emissions.csv by itself?: FALSE`).
This is *why* we hand-write the artifact under the task API — there is no free
CSV to inherit. It is not redundant with, and does not clobber, any
CodeCarbon-written file (the task API produces none).

## Resolved design question: `final_emissions_data` (acted on 2026-06-10)

The session tracker exposes the rich object in-memory via
**`tracker$final_emissions_data`** (verified: it carries `$emissions`,
`$duration`, etc. after `stop()`). The old code comment claimed `stop()`
"returns only a numeric" — true of the *return value*, but the rich object is
available on the tracker.

This is now what `tracker_stop()` uses: it reads `final_emissions_data`,
builds the **same uniform row** as `carbon_step()`/`carbon_run()`/
`carbon_track()` via `carbon_emissions_row()`, and appends it through
`carbon_write_artifact()`. The earlier idea of also moving `carbon_step()`
onto the session API was **rejected** by the verification probe:

1. **`final_emissions_data` is CUMULATIVE, not per-cycle** (verified on
   3.2.8: two 1.5 s start/stop cycles on one tracker reported duration ≈ 3.0
   then ≈ 5.0, emissions 1.98e-5 then 3.00e-5; the `stop()` scalar is
   cumulative too). Per-step rows from the session API would therefore be
   wrong — the task API stays the right backend for step/run/track. For
   `tracker_stop()` this is acceptable and documented: each session row
   reports totals since the tracker was created; use one `carbon_init()` per
   separately-measured session.
2. **Attribute stability** — `final_emissions_data` is undocumented, so
   `tracker_stop()` wraps it in `tryCatch` and degrades to the `stop()`
   scalar (an otherwise-NA "none" row with `emissions_total` filled).
3. Session `start()` overhead is moot since only global tracking uses it.

## Current status (MVP)

Working and MVP-ready as of the task-API switch. Verified:

- `R CMD check` (`--no-manual --no-build-vignettes`): **Status OK** — 0 errors,
  0 warnings, 0 notes.
- Full `testthat` suite passes (io, measure, registry, run, step, carbonbench,
  utils).
- Real CodeCarbon run: rich fields populate (`emissions_total`, `duration`,
  `country_name`, `cpu_count`, ...) and the CSV artifact accumulates rows.
- Failure paths: an unwritable artifact destination is swallowed (measurement
  still returns its result + in-memory log); a `stop_task()` failure falls back
  to a clean NA "none" row instead of crashing.
- `carbon_track()` / `carbon_track_all()` were realigned onto
  `carbon_measure()` as well (registry-default tracker, shared log row plus
  `args`/`result` list-columns, same best-effort artifact), closing the
  "Deferred" item in `docs/api_residual_cleanup_plan.md`. Only
  `carbon_bench()` still calls `start_task()`/`stop_task()` directly, with its
  own benchmark-shaped row.

Not blocking MVP, but outstanding:

- The Python-backed check used toy inputs (`1:1e5 |> sqrt() |> sum()`). The
  actual workshop pipelines in `inst/*.R` (quanteda / topicmodel) have **not**
  been run end-to-end against the new code. They use only public functions, so
  they should be fine, but running one is the highest-value remaining check
  before the workshop.
- The output-shape change (11 -> ~38 columns; original 11 names preserved as a
  subset) means COMPTEXT slides that print `colnames()`/`glimpse()` will look
  different. Worth a quick review.

## Artifact gotcha (resolved 2026-06-10: one file, one schema)

Historically, global tracking (`tracker_start()` / `tracker_stop()`, the
session API) let CodeCarbon write its **native** column schema to
`emissions.csv`, while `carbon_step()` / `carbon_run()` wrote **our** schema
(from `carbon_emissions_row()`) to the same default file — and
`carbon_write_artifact()`'s schema guard would *overwrite* a mismatched file
rather than append. Resolved by making the artifact single-schema:

- The default artifact is now **`emissions_r.csv`** everywhere
  (`carbon_init()`, the registry fallback, `carbon_measure()`,
  `carbon_read()`), distinct from CodeCarbon's native name.
- `carbon_new_tracker()` passes **`save_to_file = FALSE`** (kwarg-guarded;
  verified supported on 3.2.8 — no native CSV is written at all), so
  CodeCarbon never writes its own schema anywhere. Beware: the original
  `py_has_kwarg()` was broken (`py_to_r()` on `signature().parameters`
  returns the OrderedDict *methods*, so every kwarg probe returned FALSE —
  `offline` had silently never been applied either). It now `list()`s the
  parameter keys. Without that fix the session API rewrites the artifact
  with the native schema on every `stop()`, clobbering it.
- `tracker_stop()` writes the uniform tidycarbon row itself, like every other
  tracking function. The schema guard still protects against stale/legacy
  files, but mixed-schema collisions can no longer occur in normal use.
- `carbon_bench()` is the deliberate exception: in-memory benchmark rows
  only, no CSV (its internal session uses raw `tracker$start()`/`stop()`).
