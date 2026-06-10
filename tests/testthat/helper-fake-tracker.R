# Fake CodeCarbon trackers that exercise the R code paths without a live
# Python backend (the pattern from docs/api_residual_cleanup_plan.md Step 8).

# A CodeCarbon-shaped emissions object, as returned by tracker$stop_task().
# carbon_emissions_row() reads these fields by name.
fake_emissions <- function(emissions = 0.0001) {
  list(
    timestamp = "2026-06-10T00:00:00",
    duration = 1.5, emissions = emissions, energy_consumed = 2,
    cpu_energy = 1, ram_energy = 0.5, gpu_energy = 0.5,
    emissions_rate = 0.001, cpu_power = 15, gpu_power = 0, ram_power = 3,
    water_consumed = 1e-4, project_name = "fake", run_id = "run-1",
    experiment_id = "exp-1", country_name = "Testland", cpu_count = 8
  )
}

# Task-API backend stub: only start_task()/stop_task()/output_dir are touched
# by carbon_measure(). stop_task() returns the rich emissions object in memory.
fake_tracker <- function(output_dir = tempdir(), emissions = 0.0001) {
  list(
    output_dir = output_dir,
    start_task = function() NULL,
    stop_task  = function() fake_emissions(emissions = emissions)
  )
}

# Write a one-row CodeCarbon-shaped emissions CSV and return its directory.
write_emissions_csv <- function(file = "emissions.csv",
                                dir = file.path(tempdir(), basename(tempfile("em")))) {
  dir.create(dir, showWarnings = FALSE, recursive = TRUE)
  utils::write.csv(
    data.frame(
      timestamp = "2026-06-10T00:00:00",
      duration = 1.5, energy_consumed = 2, cpu_energy = 1,
      ram_energy = 0.5, gpu_energy = 0.5
    ),
    file.path(dir, file),
    row.names = FALSE
  )
  dir
}
