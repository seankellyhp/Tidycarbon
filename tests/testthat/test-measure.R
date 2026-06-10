# carbon_measure() is the shared CSV-tail core for carbon_step()/carbon_run().

# 5. With no new CSV row, the log falls back to the 11-column "none" shape and
#    still captures the run() value, wall time and tracker$stop() emissions.
test_that("carbon_measure() builds the fallback log when the CSV does not grow", {
  empty_dir <- file.path(tempdir(), "measure-empty")
  m <- tidycarbon:::carbon_measure(
    run = function() 1 + 1,
    tracker = fake_tracker(output_dir = empty_dir, emissions = 0.0001),
    label = "add",
    task_id = "id-1",
    output_dir = empty_dir,
    output_file = "emissions.csv"
  )

  expect_equal(m$result, 2)
  expect_equal(nrow(m$log), 1)
  expect_named(
    m$log,
    c("task_id", "label", "timestamp", "wall_time_sec", "emissions_total",
      "duration", "energy_consumed", "cpu_energy", "ram_energy",
      "gpu_energy", "output_source")
  )
  expect_identical(m$log$output_source, "none")
  expect_equal(m$log$emissions_total, 0.0001)
  expect_true(is.na(m$log$energy_consumed))
})

# 6. A fresh CSV tail row is folded into the log and output_source reports the
#    real file name (the Step 5 behaviour from the cleanup plan).
test_that("carbon_measure() pulls fields from a new CSV row and names the source file", {
  dir <- write_emissions_csv(file = "mylog.csv")
  m <- tidycarbon:::carbon_measure(
    run = function() "ok",
    tracker = fake_tracker(output_dir = dir, emissions = 0.5),
    label = "step",
    task_id = "id-2",
    output_dir = dir,
    output_file = "mylog.csv"
  )

  expect_identical(m$result, "ok")
  expect_identical(m$log$output_source, "mylog.csv")
  expect_equal(m$log$duration, 1.5)
  expect_equal(m$log$energy_consumed, 2)
})
