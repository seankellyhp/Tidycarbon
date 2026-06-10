#' Shared measurement core for carbon_step() and carbon_run()
#'
#' Runs `run()` inside a CodeCarbon task window (`start_task()` /
#' `stop_task()`), builds a rich one-row log tibble from the in-memory
#' emissions object, and writes that row to a CSV as a best-effort artifact.
#'
#' The CSV is **not** load-bearing: all emissions data comes from
#' `stop_task()` in memory, and a failed (or skipped) CSV write never affects
#' the returned result or log.
#'
#' @param run A zero-argument function executing the measured code.
#' @param tracker A CodeCarbon tracker (already resolved by the caller default).
#' @param label Label for the log row.
#' @param task_id UUID string.
#' @param output_dir,output_file Location for the CSV artifact; NULLs fall back
#'   to the tracker, then the registry from [carbon_init()]. If none resolves,
#'   the artifact is silently skipped.
#' @return list(result = <run() value>, log = <1-row tibble>).
#' @keywords internal
carbon_measure <- function(run, tracker, label, task_id, output_dir, output_file) {
  # Force the tracker before anything else, so a missing default tracker aborts
  # with "No active tracker" instead of being swallowed below.
  force(tracker)

  # Resolve the artifact location (best-effort; no longer required).
  if (is.null(output_dir)) {
    output_dir <- tryCatch(tracker$output_dir, error = function(e) NULL)
  }
  if (is.null(output_dir)) output_dir <- carbon_default_output_dir()
  if (is.null(output_file)) output_file <- carbon_default_output_file() %||% "emissions.csv"

  tryCatch(tracker$start_task(), error = function(e) NULL)

  t0 <- Sys.time()
  error_obj <- NULL
  result <- tryCatch(
    run(),
    error = function(e) { error_obj <<- e; NULL }
  )
  wall_time_sec <- as.numeric(difftime(Sys.time(), t0, units = "secs"))

  # stop_task() returns the rich (~33-field) emissions object in memory.
  emissions <- tryCatch(tracker$stop_task(), error = function(e) NULL)

  if (!is.null(error_obj)) stop(error_obj)

  log <- carbon_emissions_row(
    emissions,
    task_id       = task_id,
    label         = label,
    wall_time_sec = wall_time_sec,
    output_source = output_file
  )

  # Best-effort CSV artifact. Never load-bearing: failures are swallowed.
  if (!is.null(output_dir)) {
    carbon_write_artifact(log, output_dir, output_file)
  }

  list(result = result, log = log)
}

#' Build a rich one-row emissions tibble from a CodeCarbon task object
#'
#' Maps the in-memory object returned by `stop_task()` to a tibble. The first
#' columns (`task_id`, `label`, `timestamp`, `wall_time_sec`,
#' `emissions_total`, `duration`, `energy_consumed`, `cpu_energy`,
#' `ram_energy`, `gpu_energy`, `output_source`) preserve the historical
#' `carbon_step()` log shape as a subset; the remaining columns expose the
#' full task-API detail. Missing/`None` fields become typed `NA`.
#'
#' @param emissions The object returned by `tracker$stop_task()`, or `NULL`.
#' @param task_id,label,wall_time_sec,output_source Caller-supplied fields.
#' @return A one-row tibble.
#' @keywords internal
carbon_emissions_row <- function(emissions, task_id, label, wall_time_sec,
                                 output_source) {
  num <- function(nm) {
    v <- tryCatch(emissions[[nm]], error = function(e) NULL)
    as.numeric(v %||% NA_real_)
  }
  chr <- function(nm) {
    v <- tryCatch(emissions[[nm]], error = function(e) NULL)
    as.character(v %||% NA_character_)
  }

  tibble::tibble(
    # Historical carbon_step() log shape (kept as a subset for compatibility)
    task_id         = task_id,
    label           = label,
    timestamp       = chr("timestamp"),
    wall_time_sec   = wall_time_sec,
    emissions_total = num("emissions"),
    duration        = num("duration"),
    energy_consumed = num("energy_consumed"),
    cpu_energy      = num("cpu_energy"),
    ram_energy      = num("ram_energy"),
    gpu_energy      = num("gpu_energy"),
    output_source   = if (is.null(emissions)) "none" else output_source,

    # Full task-API detail
    project_name    = chr("project_name"),
    run_id          = chr("run_id"),
    experiment_id   = chr("experiment_id"),
    emissions_rate  = num("emissions_rate"),
    cpu_power       = num("cpu_power"),
    gpu_power       = num("gpu_power"),
    ram_power       = num("ram_power"),
    water_consumed  = num("water_consumed"),
    country_name    = chr("country_name"),
    country_iso_code = chr("country_iso_code"),
    region          = chr("region"),
    cloud_provider  = chr("cloud_provider"),
    cloud_region    = chr("cloud_region"),
    os              = chr("os"),
    python_version  = chr("python_version"),
    codecarbon_version = chr("codecarbon_version"),
    cpu_count       = num("cpu_count"),
    cpu_model       = chr("cpu_model"),
    gpu_count       = num("gpu_count"),
    gpu_model       = chr("gpu_model"),
    longitude       = num("longitude"),
    latitude        = num("latitude"),
    ram_total_size  = num("ram_total_size"),
    tracking_mode   = chr("tracking_mode"),
    on_cloud        = chr("on_cloud"),
    pue             = num("pue"),
    wue             = num("wue")
  )
}

#' Append a log row to the CSV artifact (best-effort, never load-bearing)
#'
#' Appends `log` to the file when its header matches; writes a fresh file when
#' the file is absent or carries a different (e.g. legacy) schema. Any failure
#' is swallowed so measurement is unaffected.
#'
#' @param log A one-row tibble from [carbon_emissions_row()].
#' @param output_dir,output_file CSV destination.
#' @return Invisibly `NULL`.
#' @keywords internal
carbon_write_artifact <- function(log, output_dir, output_file) {
  tryCatch({
    if (!dir.exists(output_dir)) {
      dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
    }
    path <- file.path(output_dir, output_file)
    append <- FALSE
    if (file.exists(path)) {
      hdr <- tryCatch(
        names(readr::read_csv(path, n_max = 0, show_col_types = FALSE)),
        error = function(e) NULL
      )
      # Append only when the existing schema matches; otherwise overwrite so a
      # stale/legacy file never corrupts the artifact via misaligned columns.
      append <- identical(hdr, names(log))
    }
    readr::write_csv(log, path, append = append)
  }, error = function(e) NULL)
  invisible(NULL)
}
