#' Initialize Carbon Tracker
#'
#' Creates a CodeCarbon `EmissionsTracker` and registers it as the session
#' default tracker used by [carbon_step()], [carbon_run()], [carbon_track()],
#' and [tracker_start()] / [tracker_stop()] (so those functions can be called
#' without an explicit `tracker =`).
#'
#' All tidycarbon measurement functions append uniform rows (the
#' [carbon_step()] log schema) to `output_file`. CodeCarbon's own native CSV
#' writing is disabled on the tracker, so `output_file` only ever contains
#' tidycarbon's schema.
#'
#' @param project_name Name of the project.
#' @param measure_power_secs Seconds between power measurements.
#' @param tracking_mode Tracking mode (default "machine").
#' @param output_dir Directory where `output_file` will be written
#'   (default "." --- the project root).
#' @param output_file Output CSV name (default "emissions_r.csv").
#' @param offline Logical; only applied if supported by installed CodeCarbon.
#' @return A codecarbon EmissionsTracker object, registered as the session
#'   default.
#' @export
carbon_init <- function(project_name = "rtest",
                        measure_power_secs = 1,
                        tracking_mode = "machine",
                        output_dir = ".",
                        output_file = "emissions_r.csv",
                        offline = TRUE) {
  tracker <- carbon_new_tracker(project_name, measure_power_secs,
                                tracking_mode, output_dir, output_file,
                                offline)
  .the$tracker     <- tracker
  .the$output_dir  <- output_dir
  .the$output_file <- output_file
  # Kept so tracker_stop() can rebuild the session default: CodeCarbon cannot
  # run tasks on a stopped tracker.
  .the$tracker_args <- list(project_name = project_name,
                            measure_power_secs = measure_power_secs,
                            tracking_mode = tracking_mode,
                            output_dir = output_dir,
                            output_file = output_file,
                            offline = offline)
  tracker
}


# CodeCarbon (3.3.1) overstates emissions each time its periodic live-output
# pass fires, every `api_call_interval` measurements. Nothing here uses live
# output, so trackers are created with it switched off.
LIVE_OUTPUT_OFF <- -1L

# Open a task window on a CodeCarbon tracker. The first task on a tracker also
# carries CodeCarbon's hardware start-up, so it is spent on an empty one.
task_start <- function(tracker) {
  if (inherits(tracker, "python.builtin.object") &&
      !reticulate::py_has_attr(tracker, "tidycarbon_warm")) {
    tracker$start_task()
    tracker$stop_task()
    reticulate::py_set_attr(tracker, "tidycarbon_warm", TRUE)
  }
  tracker$start_task()
}

# A function's name as written by the caller.
fun_label <- function(expr) deparse(expr, width.cutoff = 60L)[1]

# Names for the tasks of carbon_track_all(): the spec's `label`, else the
# list's own names, else the `fun =` written inline, else the caller's name
# for that function.
task_labels <- function(tasks, expr, env) {
  inline <- if (is.call(expr) && identical(expr[[1]], quote(list))) as.list(expr)[-1]
  funs <- Filter(function(nm) exists(nm, envir = env, mode = "function", inherits = FALSE),
                 ls(env))
  vapply(seq_along(tasks), function(i) {
    if (!is.null(tasks[[i]]$label)) return(as.character(tasks[[i]]$label))
    nm <- names(tasks)[i]
    if (!is.null(nm) && !is.na(nm) && nzchar(nm)) return(nm)
    spec <- if (i <= length(inline)) inline[[i]]
    if (is.call(spec) && !is.null(as.list(spec)$fun)) return(fun_label(as.list(spec)$fun))
    for (nm in funs) {
      if (identical(get(nm, envir = env), tasks[[i]]$fun)) return(nm)
    }
    NA_character_
  }, character(1))
}


#' Start global emissions tracking
#'
#' Starts the tracker's session-wide measurement window. Pair with
#' [tracker_stop()], which logs the session as one uniform emissions row.
#'
#' @param tracker A CodeCarbon tracker, or a remote tracker from
#'   [carbon_init_remote()]. Defaults to the session tracker registered by
#'   [carbon_init()].
#' @return The tracker, invisibly.
#' @export
tracker_start <- function(tracker = carbon_default_tracker()) {
  .the$session_t0 <- Sys.time()
  tracker$start()
  invisible(tracker)
}

#' Stop global emissions tracking and log the session
#'
#' Stops the tracker and turns the session's emissions into the same uniform
#' one-row tibble that [carbon_step()] / [carbon_run()] / [carbon_track()]
#' produce, appending it to the CSV artifact as a best-effort write.
#'
#' The rich per-session data comes from `tracker$final_emissions_data`, which
#' CodeCarbon stashes on the tracker after `stop()`. CodeCarbon accumulates
#' across repeated `start()`/`stop()` cycles on one tracker, so each row
#' reports totals **since the tracker was created** --- use one
#' [carbon_init()] per session you want measured separately.
#' `wall_time_sec` is measured from the most recent [tracker_start()] call.
#'
#' A stopped CodeCarbon tracker cannot measure again, so when the session
#' default is stopped a fresh tracker is created from the [carbon_init()]
#' arguments and registered in its place; later [carbon_step()] /
#' [carbon_run()] / [carbon_track()] calls keep working. A tracker you
#' created yourself and passed explicitly is finished after this call ---
#' do not reuse it.
#'
#' @param tracker A CodeCarbon tracker, or a remote tracker from
#'   [carbon_init_remote()]. Defaults to the session tracker registered by
#'   [carbon_init()].
#' @param label Label for the log row (default "session").
#' @param task_id Optional UUID string for joining/identification.
#' @param output_dir Directory for the CSV artifact. If NULL, falls back to
#'   `tracker$output_dir` then the value registered by [carbon_init()]; if none
#'   resolves, the artifact is skipped.
#' @param output_file CSV filename for the artifact. If NULL, falls back to the
#'   value registered by [carbon_init()] (default "emissions_r.csv").
#' @return A rich one-row emissions tibble (the [carbon_step()] log shape).
#'   With a remote tracker, the provider-side estimate for the window (see
#'   [carbon_init_remote()]).
#' @export
tracker_stop <- function(tracker = carbon_default_tracker(),
                         label = "session",
                         task_id = uuid::UUIDgenerate(),
                         output_dir = NULL,
                         output_file = NULL) {
  force(tracker)

  if (is_remote(tracker)) {
    return(remote_log(tracker, tracker$stop(), task_id, label))
  }

  if (is.null(output_dir)) {
    output_dir <- tryCatch(tracker$output_dir, error = function(e) NULL)
  }
  if (is.null(output_dir)) output_dir <- carbon_default_output_dir()
  if (is.null(output_file)) output_file <- carbon_default_output_file()

  scalar <- tryCatch(as.numeric(tracker$stop()), error = function(e) NA_real_)

  # The rich object CodeCarbon stashes on the tracker after stop(). It is
  # undocumented, so degrade to the stop() scalar if a version drops it.
  emissions <- tryCatch(tracker$final_emissions_data, error = function(e) NULL)

  t0 <- .the$session_t0
  .the$session_t0 <- NULL
  wall_time_sec <- if (is.null(t0)) NA_real_ else
    as.numeric(difftime(Sys.time(), t0, units = "secs"))

  log <- carbon_emissions_row(
    emissions,
    task_id       = task_id,
    label         = label,
    wall_time_sec = wall_time_sec,
    output_source = output_file
  )
  if (is.na(log$emissions_total) && !is.na(scalar)) {
    log$emissions_total <- scalar
  }

  if (!is.null(output_dir)) {
    carbon_write_artifact(log, output_dir, output_file)
  }

  # A stopped CodeCarbon tracker cannot measure again (its scheduler is
  # destroyed, and start_task() then raises). If we just stopped the session
  # default, register a fresh tracker from the carbon_init() arguments so
  # subsequent carbon_step()/carbon_run()/carbon_track() keep working.
  if (identical(tracker, .the$tracker) && !is.null(.the$tracker_args)) {
    .the$tracker <- tryCatch(do.call(carbon_new_tracker, .the$tracker_args),
                             error = function(e) NULL)
  }

  log
}

#' Track emissions for a single function call
#'
#' Calls `fun(...)` inside a CodeCarbon task window via the shared measurement
#' core ([carbon_measure()]), so it behaves like [carbon_step()] /
#' [carbon_run()]: the rich emissions row comes from `stop_task()` in memory
#' and is appended to a CSV as a best-effort artifact (never read back).
#'
#' @param fun A function to call.
#' @param ... Arguments passed to `fun`.
#' @param tracker A CodeCarbon tracker, or a remote tracker from
#'   [carbon_init_remote()]. Defaults to the session tracker registered by
#'   [carbon_init()].
#' @param label Optional human-readable label. Defaults to the deparsed `fun`.
#' @param task_id Optional UUID string for joining/identification.
#' @param output_dir Directory for the CSV artifact. If NULL, falls back to
#'   `tracker$output_dir` then the value registered by [carbon_init()]; if none
#'   resolves, the artifact is skipped.
#' @param output_file CSV filename for the artifact. If NULL, falls back to the
#'   value registered by [carbon_init()] (default "emissions_r.csv").
#' @return A rich one-row emissions tibble (the [carbon_step()] log shape) with
#'   `args` and `result` list-columns added after `label`. With a remote
#'   tracker the emissions columns are the provider-side estimate described in
#'   [carbon_init_remote()].
#' @export
carbon_track <- function(fun, ...,
                         tracker = carbon_default_tracker(),
                         label = NULL,
                         task_id = uuid::UUIDgenerate(),
                         output_dir = NULL,
                         output_file = NULL) {
  if (is.null(label)) label <- deparse1(substitute(fun))
  stopifnot(is.function(fun))

  run <- function() fun(...)
  m <- carbon_measure(run, tracker, label, task_id, output_dir, output_file)

  tibble::add_column(
    m$log,
    args   = list(list(...)),
    result = list(m$result),
    .after = "label"
  )
}

#' Track emissions for a list of function calls
#'
#' Maps [carbon_track()] over a list of function+args specs, e.g.
#' `list(list(fun = head, args = list(n = 3), label = "head3"), ...)`.
#' `label` is optional per spec: without one, a task is labelled by its name
#' in `tasks`, else by the name of its function.
#'
#' @param tasks A list of specs: `list(fun = <function>, args = <list>,
#'   label = <optional string>)`.
#' @param tracker A CodeCarbon tracker, or a remote tracker from
#'   [carbon_init_remote()]. Defaults to the session tracker registered by
#'   [carbon_init()].
#' @param output_dir,output_file Passed to [carbon_track()] for the CSV
#'   artifact.
#' @return A tibble with one row per task, as returned by [carbon_track()].
#' @export
carbon_track_all <- function(tasks,
                             tracker = carbon_default_tracker(),
                             output_dir = NULL,
                             output_file = NULL) {
  labels <- task_labels(tasks, substitute(tasks), parent.frame())

  purrr::map2_dfr(tasks, labels, function(spec, label) {
    do.call(
      carbon_track,
      c(
        list(fun = spec$fun, tracker = tracker, label = label,
             output_dir = output_dir, output_file = output_file),
        spec$args
      )
    )
  })
}
