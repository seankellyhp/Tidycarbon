#' Track emissions for a whole pipeline/expression
#'
#' Runs an expression under a single `tracker$start()` / `tracker$stop()` window.
#'
#' @param expr An expression to evaluate (captured).
#' @param tracker A CodeCarbon tracker. Defaults to the session tracker
#'   registered by [carbon_init()].
#' @param label Optional label for the run.
#' @param task_id Optional UUID string.
#' @param output_dir Directory containing the emissions CSV. If NULL, falls back
#'   to `tracker$output_dir` then the value registered by [carbon_init()].
#' @param output_file CSV filename. If NULL, falls back to the value registered
#'   by [carbon_init()] (default "emissions.csv").
#'
#' @return A list with:
#'   - `result`: the evaluated expression
#'   - `log`: a 1-row tibble with emissions/time and CSV-derived fields
#' @export
carbon_run <- function(expr,
                       tracker = carbon_default_tracker(),
                       label = "pipeline",
                       task_id = uuid::UUIDgenerate(),
                       output_dir = NULL,
                       output_file = NULL) {

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
  res <- tryCatch(
    eval(substitute(expr), envir = parent.frame()),
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
      output_source = "emissions.csv"
    )
  }

  list(result = res, log = log)
}
