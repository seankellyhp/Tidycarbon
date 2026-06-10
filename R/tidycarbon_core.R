#' Initialize Carbon Tracker
#'
#' Creates a CodeCarbon `EmissionsTracker` and registers it as the session
#' default tracker used by [carbon_step()] and [carbon_run()] (so those
#' functions can be called without an explicit `tracker =`).
#'
#' @param project_name Name of the project.
#' @param measure_power_secs Seconds between power measurements.
#' @param tracking_mode Tracking mode (default "machine").
#' @param output_dir Directory where `output_file` will be written
#'   (default "." --- the project root).
#' @param output_file Output CSV name (default "emissions.csv").
#' @param offline Logical; only applied if supported by installed CodeCarbon.
#' @return A codecarbon EmissionsTracker object, registered as the session
#'   default.
#' @export
carbon_init <- function(project_name = "rtest",
                        measure_power_secs = 1,
                        tracking_mode = "machine",
                        output_dir = ".",
                        output_file = "emissions.csv",
                        offline = TRUE) {
  tracker <- carbon_new_tracker(project_name, measure_power_secs,
                                tracking_mode, output_dir, output_file,
                                offline)
  .the$tracker     <- tracker
  .the$output_dir  <- output_dir
  .the$output_file <- output_file
  tracker
}


#' Stop Carbon Tracker
#'
#' @param tracker codecarbon EmissionsTracker object
#' @return Stops Global Emissions Tracker
#' @export
tracker_stop <- function(tracker) {

  tracker$stop()
}

#' Start Carbon Tracker
#'
#' @param tracker codecarbon EmissionsTracker object
#' @return Starts Global Emissions Tracker
#' @export
tracker_start <- function(tracker) {

  tracker$start()
}

#' Track emissions for a single function
#'
#' @param fun Arbitrary function
#' @param ... Function inputs
#' @param tracker codecarbon EmissionsTracker object
#' @param task_id Unique ID of function task
#' @return A tibble of function results and emissions
#' @export
carbon_track <- function(fun, ..., tracker, task_id = uuid::UUIDgenerate()) { # carbon_track()
  stopifnot(is.function(fun))

  tracker$start_task()

  # Run user function
  result <- fun(...)

  # stop_task() RETURNS the emissions data
  emissions <- tracker$stop_task()

  tibble::tibble(

    # Metadata
    project_name    = emissions$project_name,
    run_id          = emissions$run_id,
    experiment_id   = emissions$experiment_id,
    task_id         = task_id,
    fun             = deparse(substitute(fun)),
    args            = list(list(...)),
    result          = list(result),

    # Emissions data
    timestamp           = emissions$timestamp,
    duration            = emissions$duration,
    emissions_total     = emissions$emissions,
    emissions_rate      = emissions$emissions_rate,
    cpu_power           = emissions$cpu_power,
    gpu_power           = emissions$gpu_power,
    ram_power           = emissions$ram_power,
    cpu_energy          = emissions$cpu_energy,
    gpu_energy          = emissions$gpu_energy,
    ram_energy          = emissions$ram_energy,
    energy_consumed     = emissions$energy_consumed,
    water_consumed      = emissions$water_consumed,
    country_name        = emissions$country_name,
    country_iso_code    = emissions$country_iso_code,
    region              = emissions$region,
    cloud_provider      = emissions$cloud_provider,
    cloud_region        = emissions$cloud_region,
    os                  = emissions$os,
    python_version      = emissions$python_version,
    codecarbon_version  = emissions$codecarbon_version,
    cpu_count           = emissions$cpu_count,
    cpu_model           = emissions$cpu_model,
    gpu_count           = emissions$gpu_count,
    gpu_model           = emissions$gpu_model,
    longitude           = emissions$longitude,
    latitude            = emissions$latitude,
    ram_total_size      = emissions$ram_total_size,
    tracking_mode       = emissions$tracking_mode,
    on_cloud            = emissions$on_cloud,
    pue                 = emissions$pue,
    wue                 = emissions$wue
  )
}

#' Track Emissions for a list of functions
#'
#' @param tasks list of functions and arguments like list(fun = function, args = list(a = 1, b = 2))
#' @param tracker codecarbon EmissionsTracker object
#' @return A tibble of function results and emissions
#' @export
carbon_track_all <- function(tasks, tracker) {

  tasks |>
    purrr::map_dfr(function(spec) {
      do.call(
        carbon_track,
        c(
          list(fun = spec$fun, tracker = tracker),
          spec$args
        )
      )
    })
}
