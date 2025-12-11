
# You can learn more about package authoring with RStudio at:
#
#   https://r-pkgs.org
#
# Some useful keyboard shortcuts for package authoring:
#
#   Install Package:           'Ctrl + Shift + B'
#   Check Package:             'Ctrl + Shift + E'
#   Test Package:              'Ctrl + Shift + T'

#' Initialize Carbon Tracker
#'
#' @param project_name Name of the project
#' @param measure_power_secs Seconds between power measurements
#' @param tracking_mode Tracking mode (default "machine")
#' @return A codecarbon EmissionsTracker object
#' @export
carbon_init <- function(project_name = "rtest",
                        measure_power_secs = 10,
                        tracking_mode = "machine") {
  reticulate::py_require("codecarbon")
  carbon <- reticulate::import("codecarbon")
  # Fails offline - why would this need internet? Offline.
  # Can I save the uv python project to my project folder for replication?

  # Maybe have a flag, offline=TRUE

  carbon$EmissionsTracker(
    project_name = project_name,
    measure_power_secs = measure_power_secs,
    tracking_mode = tracking_mode
  )
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
