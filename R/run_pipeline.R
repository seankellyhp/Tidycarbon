#' Track emissions for a whole pipeline/expression
#'
#' Runs an expression inside one CodeCarbon task, so the same tracker can be
#' reused for any number of runs and each is measured on its own.
#'
#' Runs are not written to the emissions CSV as they finish. CodeCarbon writes
#' the total, and one row per run to `emissions_base_<run_id>.csv`, when the
#' tracker is stopped with [tracker_stop()].
#'
#' @param expr An expression to evaluate (captured).
#' @param tracker A CodeCarbon tracker from `carbon_init_pipe()`, or a
#'   remote tracker from [carbon_init_remote()].
#' @param label Optional label for the run.
#' @param task_id Optional UUID string.
#' @param output_dir,output_file No longer used; kept so existing calls keep
#'   working.
#'
#' @return A list with:
#'   - `result`: the evaluated expression
#'   - `log`: a 1-row tibble with time, energy and emissions, or
#'     with a remote tracker the provider-side estimate described in
#'     [carbon_init_remote()]
#' @export
carbon_run <- function(expr,
                       tracker,
                       label = "pipeline",
                       task_id = uuid::UUIDgenerate(),
                       output_dir = NULL,
                       output_file = "emissions.csv") {

  if (is_remote(tracker)) {
    tracker$start()
    res <- eval(substitute(expr), envir = parent.frame())
    return(list(result = res, log = remote_log(tracker$stop(), task_id, label)))
  }

  task_start(tracker, task_id)

  t0 <- Sys.time()
  res <- tryCatch(
    eval(substitute(expr), envir = parent.frame()),
    error = function(e) { tracker$stop_task(); stop(e) }
  )
  wall_time_sec <- as.numeric(difftime(Sys.time(), t0, units = "secs"))

  log <- task_log(tracker$stop_task(), task_id, label, wall_time_sec)

  list(result = res, log = log)
}
