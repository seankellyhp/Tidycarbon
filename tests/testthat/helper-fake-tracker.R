# Fake CodeCarbon trackers that exercise the R code paths without a live
# Python backend (the pattern from docs/api_residual_cleanup_plan.md Step 8).

# CSV-tail backend stub: only start()/stop()/output_dir are touched by
# carbon_measure(). stop() returns a bare numeric (kgCO2), matching the
# lossy CodeCarbon versions carbon_step() is written to tolerate.
fake_tracker <- function(output_dir = tempdir(), emissions = 0.0001) {
  list(
    output_dir = output_dir,
    start = function() NULL,
    stop = function() emissions
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
