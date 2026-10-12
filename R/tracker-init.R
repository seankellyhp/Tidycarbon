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
    # parameters is an OrderedDict; py_to_r() on it yields the dict *methods*
    # (copy/get/items/...), not the parameter names, so list() the keys.
    keys <- reticulate::import_builtins()$list(sig$parameters$keys())
    arg_name %in% reticulate::py_to_r(keys)
  }, error = function(e) FALSE)
}

#' Build a CodeCarbon EmissionsTracker (non-registering)
#'
#' Creates a CodeCarbon `EmissionsTracker` (or, with `offline = TRUE`, an
#' `OfflineEmissionsTracker`) via reticulate and returns the Python tracker
#' object without registering it as the session default. Used internally by
#' [carbon_init()] and [carbon_bench()].
#'
#' @param project_name Project name stored by CodeCarbon.
#' @param measure_power_secs Sampling interval (seconds).
#' @param tracking_mode CodeCarbon tracking mode (e.g., "machine").
#' @param output_dir Directory where `output_file` will be written. Created if
#'   it does not exist.
#' @param output_file Output CSV name (default "emissions_r.csv").
#' @param offline Logical; `TRUE` builds an `OfflineEmissionsTracker`, which
#'   makes no network request and needs `country_iso_code`.
#' @param country_iso_code 3-letter ISO country code, required when
#'   `offline = TRUE`.
#'
#' @return A Python `codecarbon.emissions_tracker.EmissionsTracker` (or
#'   `OfflineEmissionsTracker`) object.
#' @keywords internal
carbon_new_tracker <- function(project_name, measure_power_secs,
                               tracking_mode, output_dir, output_file,
                               offline = FALSE, country_iso_code = NULL) {
  if (isTRUE(offline)) {
    if (!is.character(country_iso_code) || length(country_iso_code) != 1 ||
        is.na(country_iso_code) || nchar(country_iso_code) != 3) {
      rlang::abort(c(
        "`offline = TRUE` needs `country_iso_code`, a 3-letter ISO code such as \"DEU\".",
        i = "Offline, CodeCarbon cannot look up where this machine is."
      ))
    }
  } else if (!is.null(country_iso_code)) {
    rlang::abort("`country_iso_code` is only used with `offline = TRUE`.")
  }

  # CodeCarbon refuses a folder that does not exist, and only logs it: the
  # tracker comes back broken and fails at its first measurement.
  if (!dir.exists(output_dir) &&
      !dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)) {
    rlang::abort(paste0("Cannot create `output_dir` \"", output_dir, "\"."))
  }

  reticulate::py_require("codecarbon")
  carbon <- reticulate::import("codecarbon")

  tracker_ctor <- if (isTRUE(offline)) carbon$OfflineEmissionsTracker else carbon$EmissionsTracker
  args <- list(
    project_name = project_name,
    measure_power_secs = measure_power_secs,
    tracking_mode = tracking_mode,
    output_dir = output_dir,
    output_file = output_file,
    api_call_interval = LIVE_OUTPUT_OFF
  )
  if (isTRUE(offline)) args$country_iso_code <- toupper(country_iso_code)
  # tidycarbon writes its own uniform artifact (carbon_write_artifact()); the
  # native CodeCarbon CSV has a different schema, so suppress it to keep
  # output_file single-schema.
  if (isTRUE(py_has_kwarg(carbon$EmissionsTracker, "save_to_file"))) {
    args$save_to_file <- FALSE
  }

  do.call(tracker_ctor, args)
}
