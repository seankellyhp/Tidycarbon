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
#' Wraps a single function call `.f(.data, ...)` in a CodeCarbon task, so each
#' step is measured on its own and one tracker can be reused for every step of
#' a pipeline.
#'
#' Steps are not written to the emissions CSV as they run. CodeCarbon writes
#' the run total, and one row per step to `emissions_base_<run_id>.csv`, when
#' the tracker is stopped with [tracker_stop()].
#'
#' @param .data Input data (pipe LHS).
#' @param .f Function to apply to `.data` (must accept `.data` as first arg).
#' @param ... Passed to `.f`.
#' @param tracker A CodeCarbon tracker from `carbon_init_pipe()`, or a
#'   remote tracker from [carbon_init_remote()].
#' @param label Optional human-readable label for the step.
#' @param task_id Optional UUID string for joining/identification.
#' @param output_dir,output_file No longer used; kept so existing calls keep
#'   working.
#'
#' @return The transformed object (result of `.f(.data, ...)`) with a
#'   `carbon_log` attribute (tibble). With a remote tracker each row is the
#'   provider-side estimate described in [carbon_init_remote()].
#' @export
carbon_step <- function(.data,
                        .f,
                        ...,
                        tracker,
                        label = NULL,
                        task_id = uuid::UUIDgenerate(),
                        output_dir = NULL,
                        output_file = "emissions.csv") {

  stopifnot(is.function(.f))
  if (is.null(label)) label <- deparse(substitute(.f))

  # Run the upstream steps now: `.data` is a lazy promise, and forcing it inside
  # this step's tracking window would nest the previous step's work in it.
  force(.data)

  if (is_remote(tracker)) {
    tracker$start()
    out <- .f(.data, ...)
    log_row <- remote_log(tracker$stop(), task_id, label)
    attr(out, "carbon_log") <- dplyr::bind_rows(attr(.data, "carbon_log"), log_row)
    return(out)
  }

  task_start(tracker, task_id)

  t0 <- Sys.time()
  out <- tryCatch(
    .f(.data, ...),
    error = function(e) { tracker$stop_task(); stop(e) }
  )
  wall_time_sec <- as.numeric(difftime(Sys.time(), t0, units = "secs"))

  log_row <- task_log(tracker$stop_task(), task_id, label, wall_time_sec)

  prev <- attr(.data, "carbon_log")
  attr(out, "carbon_log") <- dplyr::bind_rows(prev, log_row)

  out
}
