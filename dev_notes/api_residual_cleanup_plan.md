# Implementation Plan: Residual API Cleanup

Executable, code-level plan for removing the code left outdated by the
`api_cleanup` branch work (see `docs/api_cleanup.md` and
`docs/api_cleanup_implementation_plan.md`, both implemented in `7b8ca38`).
Work on the `api_cleanup` branch.

**Validation status.** The risky parts of this plan were dry-run on a
throwaway copy of the package before writing this document:

- Deleting `NAMESPACE` and running `roxygen2::roxygenise()` regenerates it
  cleanly (Step 4), and roxygen auto-deletes stale `.Rd` files it generated.
- **Plain `@export` on `autoplot.carbonbench` produces
  `export(autoplot.carbonbench)`, NOT `S3method(autoplot,carbonbench)`** —
  the method silently loses registration. The `@method autoplot carbonbench`
  tag in Step 4.2 is the validated fix; do not skip it.
- The expected post-migration export surface in Step 4.5 is the actual
  observed output, not a guess.

Steps 5–6 (output_source fix, deduplication helper) are design-validated
against the current sources but were not executed; their risk notes flag the
one subtle point each.

## Ground rules

- The whole point of Step 4 is to **retire the hand-written
  `exportPattern("^[[:alpha:]]+")` NAMESPACE** and switch to a
  roxygen-generated one. This deliberately reverses the old ground rule
  ("leave NAMESPACE untouched") from the previous plan. Do the source edits
  (Steps 1–3 and 4.1–4.4) *first*, delete `NAMESPACE` *last*, then run
  roxygen once so a single regeneration produces the final state.
- The package has never been released; there are no external users. Deleting
  compat shims outright (rather than soft-deprecating) is intentional.
- `R/.Rhistory`, `inst/.Rhistory`, and `inst/emissions.csv` are untracked,
  gitignored editor/run artifacts — but `R CMD build` still picks them up
  from the working tree (they caused the "hidden files and directories" check
  NOTE). Delete them as part of Step 7.
- Keep `%||%` in `R/utils.R` (don't import rlang's). Its roxygen block is
  removed in Step 4.4, the function stays.
- No `tests/` directory exists; verification is the script in Step 8.

## Step 1 — Delete the `carbonbench` alias (`R/carbonbench.R:94-96`)

Remove the three-line block:

```r
#' @rdname carbon_bench
#' @export
carbonbench <- carbon_bench
```

Its stated purpose was to keep `inst/quanteda_bench_carbon.R` working, but
that file was already migrated to `carbon_bench()` in `7b8ca38`; `grep -rn
carbonbench inst/ R/ README.md` confirms zero remaining *call sites* (the
only hits are the S3 class string and `.Rhistory` artifacts).

Do **not** touch:

- the `"carbonbench"` S3 class string (`R/carbonbench.R:91`),
- `autoplot.carbonbench()` (it gets new roxygen tags in Step 4.2),
- `project_name = "carbonbench"` default (line 24).

`man/carbon_bench.Rd` loses its `\alias{carbonbench}` and second usage entry
when roxygen regenerates in Step 4.

## Step 2 — Delete `carbon_init_pipe()` (`R/tracker-init.R:56-83`)

1. Remove the function *and* its roxygen block — everything from the line
   `#' Initialize a CodeCarbon EmissionsTracker (pipe-friendly setup)` (line
   56) to the end of the file. `py_has_kwarg()` and `carbon_new_tracker()`
   (lines 1–54) stay untouched.

2. Update the single remaining caller, `inst/pipe_tracker_example.R:32`:
   change `tracker <- carbon_init_pipe(` to `tracker <- carbon_init(`.
   All other arguments are identical and `output_dir = out_dir` is passed
   explicitly, so the `tempdir()`-vs-`"."` default difference is moot.
   **Keep the rest of the old-syntax section** — it is the regression test
   for the function-form `carbon_step(tokens, remove_punct = TRUE,
   tracker = ..., output_dir = ...)` path. (This section now also registers
   its tracker as the session default; harmless, since the slide-style
   section below it calls `carbon_init()` again.)

3. `man/carbon_init_pipe.Rd` should be auto-deleted by roxygen in Step 4
   (validated behavior for stale roxygen-generated Rd files); if it survives,
   `rm` it manually.

There are no other references — `grep -rn carbon_init_pipe R/ inst/ man/
README.md` after this step must return only `.Rhistory` and `docs/*.md`
(historical plans) hits.

## Step 3 — Rename `the` → `.the`

Exactly seven references, all mechanical:

- `R/zzz.R:2` — `the <- new.env(parent = emptyenv())`
- `R/zzz.R:10,16,21` — `the$tracker`, `the$output_dir`, `the$output_file`
- `R/tidycarbon_core.R:26-28` — the three assignments in `carbon_init()`

After Step 4 this is technically redundant (an explicit NAMESPACE wouldn't
export `the` anyway), but do it regardless: `the` is a hopeless grep target
and the dot prefix marks it as internal state at the definition site.

## Step 4 — Migrate NAMESPACE to roxygen-managed explicit exports

This retires `exportPattern` so the seven `@keywords internal` objects
(`carbon_new_tracker`, `py_has_kwarg`, `carbon_default_tracker`,
`carbon_default_output_dir`, `carbon_default_output_file`,
`carbon_last_row`, plus the registry env) stop leaking into the public API,
which also clears two of the three current `R CMD check` WARNINGs.

### 4.1 Give `carbon_view()` an `@export` and complete docs (`R/carbon_view.R`)

It is currently exported only by accident of `exportPattern` and has no
`@export`, no `@param`, no `@return` (the missing `use_browser` doc is the
third check WARNING). Replace the header:

```r
#' @title Launch the carbon_view shiny app
#' @name carbon_view
#' @description
#' \code{carbon_view} Launches the app to analyze code carbon data with multiples techniques.
#' @param use_browser Logical; if `TRUE` (default), open the app in the
#'   system browser.
#' @return Runs the Shiny app (called for its side effect).
#' @export
```

### 4.2 Register the S3 method explicitly (`R/carbonbench.R:98-101`)

**Load-bearing, validated:** without `@method`, roxygen emits
`export(autoplot.carbonbench)` instead of `S3method(...)` and dispatch is no
longer registered. Replace the tags above `autoplot.carbonbench` with a
documented block:

```r
#' Plot a carbonbench result
#'
#' @param object A `carbonbench` tibble returned by [carbon_bench()].
#' @param metric Which metric column to plot.
#' @param ... Unused; required by the [ggplot2::autoplot()] generic.
#' @return A ggplot object.
#' @importFrom ggplot2 autoplot
#' @importFrom rlang .data
#' @method autoplot carbonbench
#' @export
autoplot.carbonbench <- function(object, ...
```

This produces `S3method(autoplot,carbonbench)` plus a proper
`man/autoplot.carbonbench.Rd`, clearing the "undocumented code objects"
WARNING for the method.

### 4.3 Confirm every intended export already has `@export`

Already verified — the 13 current `@export` tags cover exactly:
`carbon_bench`, `carbon_collect`, `carbon_init`, `carbon_read`,
`carbon_run`, `carbon_step`, `carbon_track`, `carbon_track_all`,
`tracker_start`, `tracker_stop`, `autoplot.carbonbench`, plus the two being
deleted in Steps 1–2 (`carbonbench`, `carbon_init_pipe`). With Step 4.1's
addition, nothing else needs tagging. The internal helpers keep
`@keywords internal` and **no** `@export`.

### 4.4 Drop the `%||%` roxygen block (`R/utils.R`)

Replace the file content with:

```r
# Internal null-coalescing operator
`%||%` <- function(a, b) if (is.null(a)) b else a
```

The function stays; only the roxygen doc goes, so roxygen deletes
`man/grapes-or-or-grapes.Rd` (validated — it logs "Deleting
'grapes-or-or-grapes.Rd'"), clearing the `checkRd \name` WARNING.

### 4.5 Delete `NAMESPACE` and regenerate

```sh
rm NAMESPACE
Rscript -e 'roxygen2::roxygenise()'   # devtools is not installed on this machine
```

The regenerated `NAMESPACE` must be exactly (validated output, modulo
sorting):

```
# Generated by roxygen2: do not edit by hand

S3method(autoplot,carbonbench)
export(carbon_bench)
export(carbon_collect)
export(carbon_init)
export(carbon_read)
export(carbon_run)
export(carbon_step)
export(carbon_track)
export(carbon_track_all)
export(carbon_view)
export(tracker_start)
export(tracker_stop)
importFrom(ggplot2,autoplot)
importFrom(rlang,.data)
```

11 exported functions + 1 S3 method, down from 21 exported objects.
Internal `.Rd` files for `@keywords internal` objects remain in `man/` —
that is correct and expected.

## Step 5 — Fix the hardcoded `output_source` (`R/step.R:153`, `R/run_pipeline.R:90`)

Both log-row builders write `output_source = "emissions.csv"` even when the
data came from a differently named `output_file`. Change both to:

```r
output_source = output_file
```

The `output_source = "none"` branches (`R/step.R:139`,
`R/run_pipeline.R:76`) are correct and stay. By these lines `output_file` is
always non-NULL (the fallback chain resolved it), so no guard is needed.
*If Step 6 is done in the same pass, this fix lands inside the new helper
instead — don't apply it twice.*

## Step 6 — Factor the duplicated measurement block into one helper

`R/step.R:89-158` and `R/run_pipeline.R:26-92` are byte-identical (~55
lines): the `force(tracker)` + output fallback chain, the
start/run/stop/re-raise sequence, and the log-row tibble. Extract into a new
internal `R/measure.R`:

```r
#' Shared measurement core for carbon_step() and carbon_run()
#'
#' Resolves output defaults, runs `run()` inside a tracker start/stop window,
#' and builds the standard one-row log tibble.
#'
#' @param run A zero-argument function executing the measured code.
#' @param tracker A CodeCarbon tracker (already resolved by the caller default).
#' @param label Label for the log row.
#' @param task_id UUID string.
#' @param output_dir,output_file CSV location; NULLs fall back to the tracker,
#'   then the registry from [carbon_init()].
#' @return list(result = <run() value>, log = <1-row tibble>).
#' @keywords internal
carbon_measure <- function(run, tracker, label, task_id, output_dir, output_file) {
  # Force the tracker before the output_dir tryCatch below, so a missing
  # default tracker aborts with "No active tracker" instead of being swallowed.
  force(tracker)

  if (is.null(output_dir)) {
    output_dir <- tryCatch(tracker$output_dir, error = function(e) NULL)
  }
  if (is.null(output_dir)) output_dir <- carbon_default_output_dir()
  if (is.null(output_dir)) {
    rlang::abort("output_dir is required (pass it, or call carbon_init() first).")
  }
  if (is.null(output_file)) output_file <- carbon_default_output_file()

  before_n <- nrow(carbon_read(output_dir, output_file))

  tryCatch(tracker$start(), error = function(e) NULL)

  t0 <- Sys.time()
  error_obj <- NULL
  result <- tryCatch(
    run(),
    error = function(e) { error_obj <<- e; NULL }
  )
  wall_time_sec <- as.numeric(difftime(Sys.time(), t0, units = "secs"))

  emissions_total <- tryCatch(as.numeric(tracker$stop()), error = function(e) NA_real_)

  if (!is.null(error_obj)) stop(error_obj)

  after_df <- carbon_read(output_dir, output_file)
  after_n <- nrow(after_df)

  last <- if (after_n > before_n) {
    after_df[after_n, , drop = FALSE]
  } else {
    carbon_last_row(output_dir, output_file)
  }

  log <- if (is.null(last) || nrow(last) == 0) {
    tibble::tibble(
      task_id = task_id,
      label = label,
      timestamp = as.character(Sys.time()),
      wall_time_sec = wall_time_sec,
      emissions_total = emissions_total,
      duration = NA_real_,
      energy_consumed = NA_real_,
      cpu_energy = NA_real_,
      ram_energy = NA_real_,
      gpu_energy = NA_real_,
      output_source = "none"
    )
  } else {
    tibble::tibble(
      task_id = task_id,
      label = label,
      timestamp = as.character((last$timestamp %||% Sys.time())),
      wall_time_sec = wall_time_sec,
      emissions_total = emissions_total,
      duration = as.numeric(last$duration %||% NA_real_),
      energy_consumed = as.numeric(last$energy_consumed %||% NA_real_),
      cpu_energy = as.numeric(last$cpu_energy %||% NA_real_),
      ram_energy = as.numeric(last$ram_energy %||% NA_real_),
      gpu_energy = as.numeric(last$gpu_energy %||% NA_real_),
      output_source = output_file   # Step 5's fix lands here
    )
  }

  list(result = result, log = log)
}
```

The body is the existing duplicated block verbatim except for the final
`list(...)` return and the Step 5 fix — do not "improve" anything else.

**Caller rewrites:**

`R/step.R` — everything from the `# Force the tracker ...` comment (line 89)
to the end of `carbon_step()` becomes:

```r
  m <- carbon_measure(run, tracker, label, task_id, output_dir, output_file)

  out <- m$result
  prev <- attr(.data, "carbon_log")
  attr(out, "carbon_log") <- dplyr::bind_rows(prev, m$log)

  out
}
```

The dispatch logic above it (`substitute`, `call_form`, the two `run`
thunks) is untouched. `carbon_collect()` is untouched.

`R/run_pipeline.R` — everything from the `# Force the tracker ...` comment
(line 26) to the end of `carbon_run()` becomes:

```r
  expr_q <- substitute(expr)
  caller <- parent.frame()
  run <- function() eval(expr_q, envir = caller)

  m <- carbon_measure(run, tracker, label, task_id, output_dir, output_file)
  list(result = m$result, log = m$log)
}
```

**The one subtle point:** the current code evaluates
`eval(substitute(expr), envir = parent.frame())` *inline* in `carbon_run()`.
Once the evaluation moves into a thunk called from `carbon_measure()`,
`substitute(expr)` and `parent.frame()` MUST be captured in `carbon_run()`
itself (as `expr_q` / `caller` above) **before** the helper is called —
inside the thunk, `parent.frame()` would resolve to `carbon_measure()`'s
frame and break caller-environment evaluation. Smoke test 4 in Step 8
exercises exactly this.

## Step 7 — Housekeeping

- `README.md:116`: "Roadmap: Tests, vignettes, website, pipe operator." —
  drop "pipe operator" (this branch shipped it).
- `DESCRIPTION:18`: fix the typo "sustainablity" → "sustainability".
- Delete the local untracked artifacts so `R CMD build` stops flagging
  hidden files: `rm -f R/.Rhistory inst/.Rhistory inst/emissions.csv`.
  (All three are already gitignored.)
- `README.md` does not mention `carbonbench` or `carbon_init_pipe` — nothing
  to update there. `_pkgdown.yml` has no reference index — nothing to update.

## Step 8 — Document & verify

```sh
Rscript -e 'roxygen2::roxygenise()'   # second run after Steps 5-7; must be a no-op on NAMESPACE
git status --short man/ NAMESPACE      # only expected adds/deletes (see below)
```

Expected `man/` delta: `carbon_init_pipe.Rd` and `grapes-or-or-grapes.Rd`
deleted; `autoplot.carbonbench.Rd` and `carbon_measure.Rd` added;
`carbon_bench.Rd`, `carbon_view.Rd` modified.

Smoke script (no Python needed except test 6; run with `Rscript`):

```r
suppressMessages(pkgload::load_all(".", quiet = TRUE, export_all = FALSE))

# 1. Export surface is exactly the intended public API
stopifnot(identical(
  sort(ls("package:tidycarbon")),
  sort(c("carbon_bench", "carbon_collect", "carbon_init", "carbon_read",
         "carbon_run", "carbon_step", "carbon_track", "carbon_track_all",
         "carbon_view", "tracker_start", "tracker_stop"))))

# 2. Dispatch still works through the S3method registration
b <- structure(tibble::tibble(expr = c("a", "b"), duration = c(1, 2),
                              emissions_total = c(1, 2), energy_consumed = c(1, 2)),
               class = c("carbonbench", class(tibble::tibble())))
stopifnot(inherits(ggplot2::autoplot(b, metric = "emissions_total"), "ggplot"))

suppressMessages(pkgload::load_all(".", quiet = TRUE))  # export_all, for internals
fake <- list(output_dir = tempdir(), start = function() NULL, stop = function() 0.0001)

# 3. carbon_step through the helper: both forms, chaining, error propagation
out <- (1:10) |> carbon_step(sqrt(), tracker = fake) |> carbon_step(sum(), tracker = fake)
log <- carbon_collect(out)
stopifnot(nrow(log) == 2, log$label[1] == "sqrt()",
          identical(as.numeric(out), sum(sqrt(1:10))))
stopifnot(identical(as.integer(carbon_step(1:10, head, n = 3, tracker = fake)), 1:3))
e <- tryCatch(carbon_step(1:10, \(d) stop("boom"), tracker = fake),
              error = conditionMessage)
stopifnot(identical(e, "boom"))

# 4. carbon_run: caller-env evaluation survives the thunk refactor (Step 6 risk)
local_var <- 21
r <- carbon_run(local_var * 2, tracker = fake, label = "lv")
stopifnot(identical(r$result, 42), r$log$label == "lv")

# 5. .the registry + missing-tracker error
e2 <- tryCatch(carbon_step(1:3, sum()), error = conditionMessage)
stopifnot(grepl("No active tracker", e2))

# 6. output_source reports the real file name (Step 5)
od <- file.path(tempdir(), "osrc"); dir.create(od, showWarnings = FALSE)
write.csv(data.frame(timestamp = "x", duration = 1, energy_consumed = 1,
                     cpu_energy = 1, ram_energy = 1, gpu_energy = 1),
          file.path(od, "mylog.csv"), row.names = FALSE)
fake2 <- list(output_dir = od, start = function() NULL, stop = function() 0.1)
out3 <- carbon_step(1:3, sum(), tracker = fake2, output_file = "mylog.csv")
stopifnot(carbon_collect(out3)$output_source == "mylog.csv")

# 7. Removed objects are gone from the namespace
ns <- asNamespace("tidycarbon")
stopifnot(!exists("carbonbench", ns, inherits = FALSE),
          !exists("carbon_init_pipe", ns, inherits = FALSE),
          !exists("the", ns, inherits = FALSE))
```

Then the Python-backed checks (reuses the codecarbon env that `py_require()`
resolves automatically):

```r
tr <- carbon_init(project_name = "test", measure_power_secs = 1,
                  output_dir = tempdir())
tracker_start(tr); Sys.sleep(2); tracker_stop(tr)
out <- (1:10) |> carbon_step(sqrt()) |> carbon_step(sum())   # registry-driven
stopifnot(nrow(carbon_collect(out)) == 2)
b <- carbon_bench(a = sum(1:1e6), b = sum(as.numeric(1:1e6)), times = 2)
print(ggplot2::autoplot(b, metric = "emissions_total"))
stopifnot(identical(carbon_default_tracker(), tr))           # bench didn't hijack
```

Finally:

```sh
cd /tmp && R CMD build <pkg-path> --no-build-vignettes \
        && R CMD check tidycarbon_0.1.0.tar.gz --no-manual
```

Baseline before this plan: **3 WARNINGs, 1 NOTE** (checkRd `%||%` name;
undocumented `autoplot.carbonbench`/`the`; undocumented `use_browser`;
hidden-files NOTE). Target after: **0 WARNINGs**; the hidden-files NOTE
disappears once the `.Rhistory` artifacts are deleted (Step 7). Any *new*
finding is a regression of this plan.

## Risk notes for the implementer

1. **`@method autoplot carbonbench` is not optional** (Step 4.2). Validated:
   plain `@export` exports the function without registering the S3 method.
2. **Order matters in Step 6's `carbon_run()` rewrite**: capture
   `substitute(expr)` and `parent.frame()` before calling the helper, never
   inside the thunk.
3. **One roxygen run after all source edits.** Running `roxygenise()` while
   `carbon_init_pipe()` still exists in source will faithfully re-export it;
   the regeneration only reflects whatever tags are present at that moment.
4. **Don't add `@export` to the internal helpers** (`carbon_new_tracker`,
   `py_has_kwarg`, the `carbon_default_*` accessors, `carbon_last_row`,
   `carbon_measure`) — shrinking the export surface to the 11 public
   functions is the point of Step 4.
5. The `inst/` examples and the Shiny app use only public functions and raw
   reticulate (verified by grep) — no example breaks when the internals stop
   being exported.

---

## Deferred: `carbon_track()` / `carbon_track_all()` (explained, not planned)

> **Status (2026-06-10): resolved.** Once `carbon_step()`/`carbon_run()`
> migrated onto the task API via `carbon_measure()` (see
> `docs/measurement_backend_notes.md`), the two-backend split below
> disappeared and the deferral reason with it. `carbon_track*` were rebuilt
> on `carbon_measure()` — registry-default `tracker`, guarded task window,
> shared rich log row (plus `args`/`result` list-columns), best-effort CSV
> artifact — i.e. option 1 below, except the row builder is shared rather
> than duplicated. They remain exported. The rest of this section is the
> historical rationale.

These two (`R/tidycarbon_core.R:61-136`) are the package's oldest
measurement API and are deliberately **out of scope** here, because cleaning
them up is a design decision, not a mechanical refactor.

**What they are.** `carbon_track(fun, ..., tracker, task_id)` wraps a single
function call in CodeCarbon's *task* API (`tracker$start_task()` /
`tracker$stop_task()`) and returns one rich tibble row — ~33 columns
including `water_consumed`, hardware specs, and geolocation, far more than
the 11-column log that `carbon_step()`/`carbon_run()` assemble from the CSV
tail. `carbon_track_all(tasks, tracker)` maps it over a list of
function+args specs.

**Why they're outdated.**

- They predate the registry: `tracker` is a required argument with no
  default, so they ignore the `carbon_init()` session default that every
  other measurement function now honors. They are the only public functions
  left with the old calling convention.
- `carbon_track()`'s body is essentially the per-iteration core of
  `carbon_bench()` — the same `start_task()`/`stop_task()` + tibble pattern
  is maintained twice.
- The package now has *two parallel measurement backends*: the task API
  (rich, returned in-memory, used by `carbon_track*` and `carbon_bench`) and
  the CSV-tail-reading hack (lossy, race-prone, used by `carbon_step` and
  `carbon_run` via `carbon_read()` before/after row counting).

**Why the decision is deferred.** The right fix depends on which backend
wins long-term. The genuinely clean endgame is probably migrating
`carbon_step()`/`carbon_run()` *onto* the task API (richer rows, no CSV
races, no `output_dir` plumbing), at which point `carbon_track()` becomes an
internal building block and disappears from the API entirely. That is a
behavior change to the package's headline functions (the log column set
changes, `output_source`/CSV semantics change) and should not be smuggled
into a cleanup pass — and not right before COMPTEXT 2026, since the slides
demo the current `carbon_step()` output.

**The options, when the time comes:**

1. *Align*: give both functions `tracker = carbon_default_tracker()` and
   keep them as the documented "rich single-shot measurement" API. One-line
   change each, plus README wording. Cheapest; cements the two-backend
   split.
2. *Deprecate and absorb*: rebuild `carbon_step()`/`carbon_run()` on
   `start_task()`/`stop_task()`, expose the rich columns there, demote
   `carbon_track*` to internal helpers shared with `carbon_bench()`, and
   drop them from the export list and README. Most work; one blessed
   measurement path; this is the real "clean API".
3. *Remove outright*: viable only if nothing (including the Shiny app and
   workshop material) needs the rich columns — `inst/task_tracker_example.R`
   and `inst/test_advanced_R.R` would go with them.

Current usage to account for whenever this is picked up:
`inst/task_tracker_example.R` (both functions),
`inst/test_advanced_R.R` (`carbon_track_all`), and the README "Key
Functions" list, which advertises both.
