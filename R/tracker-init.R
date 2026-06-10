#' Check if a Python callable supports a keyword argument
#'
#' Uses Python's `inspect.signature()` to detect whether a constructor/function
#' accepts a given keyword.
#'
#' @param py_callable A Python callable (reticulate object).
#' @param arg_name A string keyword argument name to check.
#' @return Logical.
#' @keywords internal
py_has_kwarg <- function(py_callable, arg_name) {
  tryCatch({
    inspect <- reticulate::import("inspect")
    sig <- inspect$signature(py_callable)
    params <- names(reticulate::py_to_r(sig$parameters))
    arg_name %in% params
  }, error = function(e) FALSE)
}

#' Build a CodeCarbon EmissionsTracker (non-registering)
#'
#' Creates a CodeCarbon `EmissionsTracker` via reticulate and returns the Python
#' tracker object without registering it as the session default. Adds a version
#' guard for the `offline` parameter (only passed if supported by the installed
#' CodeCarbon). Used internally by [carbon_init()] and [carbon_bench()].
#'
#' @param project_name Project name stored by CodeCarbon.
#' @param measure_power_secs Sampling interval (seconds).
#' @param tracking_mode CodeCarbon tracking mode (e.g., "machine").
#' @param output_dir Directory where `output_file` will be written.
#' @param output_file Output CSV name (default "emissions.csv").
#' @param offline Logical; only applied if supported by installed CodeCarbon.
#'
#' @return A Python `codecarbon.emissions_tracker.EmissionsTracker` object.
#' @keywords internal
carbon_new_tracker <- function(project_name, measure_power_secs,
                               tracking_mode, output_dir, output_file,
                               offline) {
  reticulate::py_require("codecarbon")
  carbon <- reticulate::import("codecarbon")

  tracker_ctor <- carbon$EmissionsTracker
  args <- list(
    project_name = project_name,
    measure_power_secs = measure_power_secs,
    tracking_mode = tracking_mode,
    output_dir = output_dir,
    output_file = output_file
  )
  if (isTRUE(py_has_kwarg(tracker_ctor, "offline"))) {
    args$offline <- offline
  }

  do.call(tracker_ctor, args)
}
