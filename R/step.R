#' Collect step logs from a pipeline object
#'
#' `carbon_step()` stores logs as an attribute on the returned object.
#'
#' @param x An object returned by `carbon_step()`.
#' @return A tibble (possibly empty).
#' @export
carbon_collect <- function(x) {
  attr(x, "carbon_log") %||% tibble::tibble()
}

#' Track emissions for one pipeline step
#'
#' Wraps a single pipeline step with `tracker$start()` and `tracker$stop()`,
#' then reads the latest row from CodeCarbon's emissions CSV.
#'
#' `.f` can be supplied two ways:
#' - **Call form** (slide syntax): `carbon_step(x, tokens_ngrams(n = 1:3))`.
#'   The unevaluated call has `.data` inserted as its first argument and is
#'   evaluated in the caller's environment.
#' - **Function/symbol form**: `carbon_step(x, tokens, remove_punct = TRUE)`,
#'   `carbon_step(x, \(d) head(d, 3))`, `carbon_step(x, quanteda::tokens)`.
#'   The function is applied as `.f(.data, ...)`.
#'
#' This is robust across CodeCarbon versions where `tracker$stop()` returns only
#' a numeric (kgCO2) rather than a full data object.
#'
#' @param .data Input data (pipe LHS).
#' @param .f A function, or an unevaluated call whose first argument slot will
#'   receive `.data`.
#' @param ... Passed to `.f` in the function/symbol form (ignored, with a
#'   warning, in the call form --- supply arguments inside the call instead).
#' @param tracker A CodeCarbon tracker. Defaults to the session tracker
#'   registered by [carbon_init()].
#' @param label Optional human-readable label for the step. Defaults to the
#'   deparsed `.f`.
#' @param task_id Optional UUID string for joining/identification.
#' @param output_dir Directory containing the emissions CSV. If NULL, falls back
#'   to `tracker$output_dir` then the value registered by [carbon_init()].
#' @param output_file CSV filename. If NULL, falls back to the value registered
#'   by [carbon_init()] (default "emissions.csv").
#'
#' @return The transformed object with a `carbon_log` attribute (tibble).
#' @examples
#' \dontrun{
#' carbon_init(project_name = "demo")
#' out <- (1:10) |> carbon_step(sqrt()) |> carbon_step(sum())
#' carbon_collect(out)
#' }
#' @export
carbon_step <- function(.data,
                        .f,
                        ...,
                        tracker = carbon_default_tracker(),
                        label = NULL,
                        task_id = uuid::UUIDgenerate(),
                        output_dir = NULL,
                        output_file = NULL) {

  expr   <- substitute(.f)
  caller <- parent.frame()

  # Call form: carbon_step(x, tokens_ngrams(n = 1:3)).
  # Anonymous functions (`function(x) ...`, `\(x) ...`) parse as calls with
  # head `function`; namespaced bare functions (`quanteda::tokens`) parse as
  # calls with head `::`/`:::`. All three must take the function form.
  call_form <- is.call(expr) &&
    !identical(expr[[1L]], quote(`function`)) &&
    !identical(expr[[1L]], quote(`::`)) &&
    !identical(expr[[1L]], quote(`:::`))

  if (is.null(label)) label <- deparse1(expr)

  if (call_form) {
    if (...length() > 0) {
      rlang::warn(
        "Arguments in `...` are ignored in call form; put them inside the call."
      )
    }
    new_call <- as.call(append(as.list(expr), list(quote(.data)), after = 1L))
    eval_env <- new.env(parent = caller)
    assign(".data", .data, envir = eval_env)
    run <- function() eval(new_call, eval_env)
  } else {
    .f <- match.fun(.f)        # forces the promise; symbol & function forms
    run <- function() .f(.data, ...)
  }

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
  out <- tryCatch(
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

  log_row <- if (is.null(last) || nrow(last) == 0) {
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
      output_source = "emissions.csv"
    )
  }

  prev <- attr(.data, "carbon_log")
  attr(out, "carbon_log") <- dplyr::bind_rows(prev, log_row)

  out
}
