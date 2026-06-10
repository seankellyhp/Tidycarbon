# CLAUDE.md

Guidance for working in this repository.

## What this is

`tidycarbon` is an R package providing a tidy interface to Python's
[CodeCarbon](https://mlco2.github.io/codecarbon/) emissions tracker, bridged
via **reticulate**. CodeCarbon is auto-resolved at runtime through
`reticulate::py_require("codecarbon")` — there is no manual Python setup. The
package targets a COMPTEXT 2026 workshop; demos depend on the current
`carbon_step()` output shape, so avoid changing public output columns casually.

## Commands

`devtools` is **not** installed on this machine, deliberately — it is only a
convenience wrapper, and its underlying packages (`roxygen2`, `pkgload`,
`pkgbuild`, `rcmdcheck`, `usethis`, `testthat`) are all installed. Call them
directly:

```sh
# Regenerate NAMESPACE + man/*.Rd after editing any roxygen block
Rscript -e 'roxygen2::roxygenise()'

# Build + check (stages a temp copy itself; --no-manual avoids LaTeX)
Rscript -e 'rcmdcheck::rcmdcheck(".", args = "--no-manual", build_args = "--no-build-vignettes")'
```

For interactive/scripted verification use `pkgload`, not `library()`:

```r
pkgload::load_all(".", quiet = TRUE)                    # internals visible
pkgload::load_all(".", quiet = TRUE, export_all = FALSE) # public surface only
```

Tests live in `tests/testthat/`. Most run without a live Python backend via
the fake-tracker stubs in `tests/testthat/helper-fake-tracker.R` (`fake_tracker()`
returns an object with `start_task()`/`stop_task()`; `fake_emissions()` is the
CodeCarbon-shaped row it yields). Run them with:

```r
Rscript -e 'pkgload::load_all(".", quiet=TRUE); testthat::test_dir("tests/testthat")'
```

## Architecture

**All measurement now runs on CodeCarbon's task API** (`start_task()` /
`stop_task()`), which returns rich (~33-column) emissions data in-memory:

1. **`carbon_step()` / `carbon_run()`**: delegate to the shared core
   `R/measure.R::carbon_measure()`, which runs the code in a task window,
   builds the rich log row from the in-memory `stop_task()` object, and writes
   that row to `emissions_r.csv` as a **best-effort artifact**. The CSV is
   never read back — a failed (or skipped) write never affects the result or
   log, so it is not load-bearing. Fix measurement logic in `carbon_measure()`
   once, not twice. (History: these used to wrap `start()`/`stop()` and scrape
   the CSV tail for an ~11-column log; that backend was retired. The original
   11 column *names* are preserved as a subset of the rich log for
   compatibility.)
2. **`carbon_track()` / `carbon_track_all()`**: single-shot per-function
   wrappers, also built on `carbon_measure()` (registry-default tracker, rich
   log row plus `args`/`result` list-columns, best-effort CSV artifact). They
   were realigned to this convention after the task-API switch — the
   "Deferred" section of `docs/api_residual_cleanup_plan.md` records the
   pre-alignment state.
3. **`tracker_start()` / `tracker_stop()`** (global session tracking): the
   session API. `tracker_stop()` builds the same uniform row via
   `carbon_emissions_row()` from `tracker$final_emissions_data` (undocumented
   but verified attribute; falls back to the `stop()` scalar) and appends it
   to the same artifact. CodeCarbon accumulates across repeated
   `start()`/`stop()` cycles on one tracker (verified), so each row reports
   totals since tracker creation. The native CodeCarbon CSV is suppressed at
   tracker construction (`save_to_file = FALSE` in `carbon_new_tracker()`), so
   `emissions_r.csv` only ever carries tidycarbon's schema — every public
   tracking function except `carbon_bench()` writes the same uniform file.
4. **`carbon_bench()`**: uses `start_task()`/`stop_task()` directly with its
   own narrower per-iteration row (benchmark-shaped, not the shared log
   schema) and a throwaway tracker by default. It deliberately writes **no**
   CSV rows (its internal session uses raw `tracker$start()`/`tracker$stop()`,
   not `tracker_start()`/`tracker_stop()`).

**Session tracker registry** (`R/zzz.R`): `carbon_init()` stores the active
tracker, output paths, and its own construction args (`.the$tracker_args`) in
the package-internal `.the` environment. `tracker_stop()` uses the stored args
to register a **fresh** default tracker after stopping (a stopped CodeCarbon
tracker cannot run tasks — verified: `start_task()` raises on it), and
`tracker_start()` stashes `.the$session_t0` for the session row's wall time.
`carbon_default_tracker()` / `carbon_default_output_dir()` /
`carbon_default_output_file()` read from it, which is how `carbon_step()` and
`carbon_run()` work without an explicit `tracker =`. `.the` is internal — keep
the dot prefix.

### Source map

| File | Contents |
|------|----------|
| `R/tidycarbon_core.R` | `carbon_init()`, `tracker_start/stop()`, `carbon_track*()` |
| `R/tracker-init.R` | `carbon_new_tracker()` (internal builder), `py_has_kwarg()` |
| `R/zzz.R` | `.the` registry env + `carbon_default_*()` accessors |
| `R/step.R` | `carbon_step()`, `carbon_collect()` |
| `R/run_pipeline.R` | `carbon_run()` |
| `R/measure.R` | `carbon_measure()` (shared task-API core) + `carbon_emissions_row()`, `carbon_write_artifact()` |
| `R/carbonbench.R` | `carbon_bench()` + `autoplot.carbonbench()` |
| `R/io.R` | `carbon_read()` |
| `R/carbon_view.R` | `carbon_view()` Shiny launcher (`inst/app/app.R`) |
| `R/utils.R` | internal `%||%` |
| `inst/*.R` | runnable example scripts (not loaded by the package) |

## Conventions

- **NAMESPACE is roxygen-generated** (`# Generated by roxygen2: do not edit`).
  Never hand-edit it; change `@export`/`@keywords internal` tags and rerun
  `roxygenise()`. The public surface is intentionally small: 11 exported
  functions + the `autoplot.carbonbench` S3 method. Internal helpers carry
  `@keywords internal` and **no** `@export` — keep it that way.
- **S3 methods need an explicit `@method` tag.** `autoplot.carbonbench` uses
  `#' @method autoplot carbonbench`; without it roxygen emits
  `export(autoplot.carbonbench)` instead of `S3method(autoplot,carbonbench)`
  and dispatch silently breaks.
- `%||%` is a hand-rolled internal operator in `R/utils.R` (no roxygen doc, no
  export) — do not replace it with rlang's import.
- `carbon_run()` captures `substitute(expr)` and `parent.frame()` in its own
  body before delegating to `carbon_measure()`. If you refactor it, capture
  them **before** the call — inside the delegated thunk, `parent.frame()` would
  resolve to the helper's frame and break caller-environment evaluation.
- The package has no external users / no released version; deleting dead code
  outright (rather than soft-deprecating) is the established approach.
- Stray `.Rhistory` / `emissions.csv` artifacts in `R/` and `inst/` get picked
  up by `R CMD build`; they're gitignored — delete them before building.
