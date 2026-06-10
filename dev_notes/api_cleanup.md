# TidyCarbon API Cleanup Plan

Goal: make the package API match what is presented in the COMPTEXT 2026 slides
(`Comptext 2026(1).pptx`, especially slide 12 "A Tidy Approach Toward
Sustainability").

## Context

The slides advertise three usage patterns. The current code implements all
three *mechanisms*, but the *interfaces* don't match what the slides promise.

**Slide 12, panel 1 — global tracking:**

```r
tracker <- tidycarbon::carbon_init(
  project_name = "COMPTEXT26",
  measure_power_secs = 1,
  output_file = "emissions.csv")

tidycarbon::tracker_start(tracker)
# ... R code ...
tidycarbon::tracker_stop(tracker)
```

Gap: `carbon_init()` (`R/tidycarbon_core.R`) accepts only `project_name`,
`measure_power_secs`, and `tracking_mode` — no `output_file`, `output_dir`, or
`offline`. Those live only in the parallel constructor `carbon_init_pipe()`
(`R/tracker-init.R`), which exists solely because the two constructors were
never merged.

**Slide 12, panel 2 — pipeline steps:**

```r
tokens(big_corpus, remove_punct = TRUE, remove_symbols = TRUE, remove_numbers = TRUE) |>
  tokens_tolower() |>
  tokens_remove(stopwords("en")) |>
  tokens_wordstem() |>
  tidycarbon::carbon_step(tokens_ngrams(n = 1:3)) |>
  tidycarbon::carbon_step(dfm())
```

Gap: the current `carbon_step()` (`R/step.R`) requires a bare function plus
separately-spelled arguments **and** an explicit `tracker=` and `output_dir=`
on every step (see `inst/pipe_tracker_example.R` for how verbose this is
today). The slide passes an *unevaluated call* with the data slot omitted, and
no tracker argument at all.

**Slide 12, panel 3 — benchmarking:**

```r
carbon_bench(
  LLM  = rollama::query(...),
  DICT = quanteda.sentiment::textstat_polarity(txt, dictionary = LSD2015),
  times = 10) |>
  autoplot(metric = "emissions_total")
```

Gap: the function is named `carbonbench()` (`R/carbonbench.R`, no underscore)
and hard-errors unless given *exactly two* named expressions.
`autoplot.carbonbench()` already exists and matches the slide.

## Changes

### 1. Unify the tracker constructors

Files: `R/tidycarbon_core.R`, `R/tracker-init.R`

- Give `carbon_init()` the full signature, absorbing `carbon_init_pipe()`:

  ```r
  carbon_init <- function(project_name = "rtest",
                          measure_power_secs = 1,
                          tracking_mode = "machine",
                          output_dir = ".",
                          output_file = "emissions.csv",
                          offline = TRUE)
  ```

  - Pass `output_dir`/`output_file` through to the Python
    `codecarbon.EmissionsTracker`.
  - Keep the existing `py_has_kwarg()` version guard (`R/tracker-init.R`) so
    `offline` is only passed when the installed CodeCarbon supports it.
  - `output_dir = "."` preserves the README's promise that emissions land in
    `emissions.csv` in the project root by default.

- **Default-tracker registry.** On creation, register the tracker plus its
  `output_dir`/`output_file` in a package-internal environment (e.g.
  `the <- new.env(parent = emptyenv())` in a new `R/zzz.R`). Add an internal
  helper:

  ```r
  carbon_default_tracker <- function() {
    the$tracker %||% rlang::abort("No active tracker. Call carbon_init() first.")
  }
  ```

  This is what lets the slide's `carbon_step()` calls omit `tracker=`.

- Keep `carbon_init_pipe()` as a thin deprecated wrapper that calls
  `carbon_init()` (existing example scripts in `inst/` use it).

### 2. Pipe-call style `carbon_step()`

File: `R/step.R`

- Capture the second argument unevaluated with `substitute()` and dispatch on
  its shape:
  - **Call form** — `carbon_step(x, tokens_ngrams(n = 1:3))`: insert the piped
    data as the call's first argument
    (`as.call(append(as.list(expr), list(quote(.data)), after = 1))`) and
    evaluate in the caller's environment. This is the slide syntax.
  - **Symbol/function form** — `carbon_step(x, tokens, remove_punct = TRUE)`:
    keep today's behavior (`.f(.data, ...)`) for backward compatibility with
    `inst/pipe_tracker_example.R`. Anonymous functions (`function(x) ...`,
    `\(x) ...`) are calls whose head is `function` — treat them as the
    function form.
- `tracker` defaults to `carbon_default_tracker()`; `output_dir`/`output_file`
  default to the values registered by `carbon_init()` (explicit arguments
  still override).
- Default `label` becomes the deparsed call, e.g. `"tokens_ngrams(n = 1:3)"`.
- The measurement mechanics stay exactly as they are: `tracker$start()` /
  `tracker$stop()` around the step, last-row lookup via `carbon_read()` /
  `carbon_last_row()` (`R/io.R`), and the accumulated `carbon_log` attribute
  consumed by `carbon_collect()`.
- `carbon_run()` (`R/run_pipeline.R`) gets the same optional-tracker /
  registry-derived `output_dir` defaults, but its interface otherwise stays.

### 3. Rename benchmark to `carbon_bench()`

File: `R/carbonbench.R`

- Rename `carbonbench()` → `carbon_bench()`; keep `carbonbench <- carbon_bench`
  as an alias so `inst/quanteda_bench_carbon.R` and existing man pages keep
  working.
- Relax the validation from "exactly two named expressions" to "two or more
  named expressions". The run loop already iterates over `names(exprs)`, so
  only the check changes.
- `autoplot.carbonbench()` and the `"carbonbench"` S3 class are untouched —
  `carbon_bench(...) |> autoplot(metric = "emissions_total")` then works as on
  the slide.

### 4. Housekeeping

- `DESCRIPTION`: add `readr` and `dplyr` to Imports (already used by `R/io.R`
  and `R/step.R`); add `shiny` to Suggests (used by `carbon_view()`).
- Update roxygen blocks for the changed functions and regenerate `man/` with
  `devtools::document()`. `NAMESPACE` uses `exportPattern("^[[:alpha:]]+")`,
  so `carbon_bench` exports automatically.
- `README.md`: update the Quickstart to show the three slide-12 panels —
  global tracking with `output_file`, pipe-style `carbon_step()`, and
  `carbon_bench() |> autoplot()` — and list `carbon_step()`,
  `carbon_collect()`, `carbon_run()`, and `carbon_bench()` under
  "Key Functions".
- `_pkgdown.yml`: update any references to `carbonbench` / `carbon_init_pipe`.
- `inst/pipe_tracker_example.R`: add the new slide-style syntax alongside the
  old one.

## Verification

1. `devtools::document()` and `pkgload::load_all(".")` run cleanly
   (ideally also `R CMD check`).
2. Smoke test in R (requires reticulate + codecarbon, already configured per
   the `inst/` examples):
   - `carbon_init(project_name = "test", measure_power_secs = 1,
     output_file = "emissions.csv")` then `tracker_start()` /
     `tracker_stop()` writes `emissions.csv`.
   - A dependency-free pipe using exactly the slide syntax, with no
     `tracker=`:

     ```r
     out <- (1:10) |> carbon_step(sqrt()) |> carbon_step(sum())
     carbon_collect(out)   # 2-row log
     ```

   - `carbon_bench(a = sum(1:1e6), b = sum(as.numeric(1:1e6)), times = 2) |>
     autoplot(metric = "emissions_total")` produces a plot.
3. Re-run `inst/pipe_tracker_example.R` (old syntax) to confirm backward
   compatibility.
