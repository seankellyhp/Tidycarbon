#' Benchmark carbon emissions of two or more functions
#'
#' Runs two or more functions repeatedly and tracks emissions for each run,
#' similar in spirit to [microbenchmark::microbenchmark()]. The returned tibble
#' carries class `"carbonbench"` and can be passed to [ggplot2::autoplot()],
#' e.g. `carbon_bench(...) |> autoplot(metric = "emissions_total")`.
#'
#' @param ... Two or more named expressions or functions to benchmark.
#'   Expressions are accepted unevaluated (like
#'   `microbenchmark::microbenchmark()`), so piped calls work, e.g.
#'   `v4 = as.tokens_xptr(xtoks) |> tokens_ngrams()`. Functions are called with
#'   no arguments.
#' @param times Number of times to run each function.
#' @param tracker Optional codecarbon tracker. If `NULL`, a throwaway tracker is
#'   created and stopped internally (the session default tracker registered by
#'   [carbon_init()] is left untouched).
#' @param project_name Project name used when creating an internal tracker.
#' @param measure_power_secs Sampling interval (seconds) for the internal
#'   tracker.
#' @param warmup Logical; if `TRUE`, run each expression once before timing.
#' @return A tibble of class `carbonbench` with one row per run.
#' @export
carbon_bench <- function(..., times = 10, tracker = NULL,
                        project_name = "carbonbench",
                        measure_power_secs = .01,
                        warmup = TRUE) {
  exprs <- as.list(substitute(list(...)))[-1]
  env <- parent.frame()
  if (length(exprs) < 2 || is.null(names(exprs)) || any(names(exprs) == "")) {
    stop("carbon_bench() requires two or more named expressions, e.g. a = expr1, b = expr2")
  }

  run_one <- function(nm) {
    val <- eval(exprs[[nm]], envir = env)
    if (is.function(val)) val() else val
  }

  owns_tracker <- is.null(tracker)
  if (owns_tracker) {
    tracker <- carbon_new_tracker(project_name = project_name,
                                  measure_power_secs = measure_power_secs,
                                  tracking_mode = "machine",
                                  output_dir = tempdir(),
                                  output_file = "emissions.csv",
                                  offline = TRUE)
    tracker_start(tracker)
    on.exit(tracker_stop(tracker), add = TRUE)
  }

  if (isTRUE(warmup)) {
    for (nm in names(exprs)) {
      invisible(run_one(nm))
    }
    gc(verbose = FALSE)
  }

  runs <- expand.grid(iter = seq_len(times), expr = names(exprs),
                      KEEP.OUT.ATTRS = FALSE, stringsAsFactors = FALSE)
  runs <- runs[sample(nrow(runs)), , drop = FALSE]

  rows <- purrr::map_dfr(seq_len(nrow(runs)), function(i) {
    nm <- runs$expr[i]
    task_id <- paste(nm, runs$iter[i], sep = "_")

    tracker$start_task()
    result <- run_one(nm)
    rm(result)
    emissions <- tracker$stop_task()

    tibble::tibble(
      project_name    = emissions$project_name,
      run_id          = emissions$run_id,
      experiment_id   = emissions$experiment_id,
      task_id         = task_id,
      expr            = nm,
      iter            = runs$iter[i],
      timestamp       = emissions$timestamp,
      duration        = emissions$duration,
      emissions_total = emissions$emissions,
      emissions_rate  = emissions$emissions_rate,
      cpu_power       = emissions$cpu_power,
      gpu_power       = emissions$gpu_power,
      ram_power       = emissions$ram_power,
      cpu_energy      = emissions$cpu_energy,
      gpu_energy      = emissions$gpu_energy,
      ram_energy      = emissions$ram_energy,
      energy_consumed = emissions$energy_consumed
    )
  })

  structure(rows, class = c("carbonbench", class(rows)))
}

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
autoplot.carbonbench <- function(object, metric = c("duration", "emissions_total",
                                                    "energy_consumed"), ...) {
  metric <- match.arg(metric)
  ggplot2::ggplot(object, ggplot2::aes(x = .data$expr, y = .data[[metric]],
                                       fill = .data$expr)) +
    ggplot2::geom_violin(alpha = 0.4, trim = FALSE) +
    ggplot2::geom_jitter(width = 0.1, height = 0, alpha = 0.7) +
    ggplot2::labs(x = NULL, y = metric,
                  title = paste("carbonbench:", metric)) +
    ggplot2::theme_minimal() +
    ggplot2::theme(legend.position = "none")
}
