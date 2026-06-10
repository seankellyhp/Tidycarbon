# carbon_measure() is the shared measurement core for carbon_step()/carbon_run().
# It runs the code in a CodeCarbon task window (start_task()/stop_task()), builds
# a rich in-memory log row, and writes that row to a CSV as a best-effort
# artifact that is never read back.

# 5. The log carries the rich task-API fields, keeps the historical 11-column
#    shape as a subset, names the artifact file, and the row is written to disk.
test_that("carbon_measure() builds a rich log from stop_task() and writes the artifact", {
  dir <- file.path(tempdir(), "measure-rich")
  unlink(dir, recursive = TRUE)
  m <- tidycarbon:::carbon_measure(
    run = function() "ok",
    tracker = fake_tracker(output_dir = dir, emissions = 0.5),
    label = "step",
    task_id = "id-2",
    output_dir = dir,
    output_file = "mylog.csv"
  )

  expect_identical(m$result, "ok")
  expect_equal(nrow(m$log), 1)

  # Historical carbon_step() columns preserved as a subset.
  expect_true(all(
    c("task_id", "label", "timestamp", "wall_time_sec", "emissions_total",
      "duration", "energy_consumed", "cpu_energy", "ram_energy",
      "gpu_energy", "output_source") %in% names(m$log)
  ))
  # Rich task-API fields now exposed too.
  expect_true(all(
    c("emissions_rate", "water_consumed", "country_name") %in% names(m$log)
  ))

  expect_identical(m$log$output_source, "mylog.csv")
  expect_equal(m$log$emissions_total, 0.5)
  expect_equal(m$log$duration, 1.5)
  expect_equal(m$log$energy_consumed, 2)
  expect_equal(m$log$water_consumed, 1e-4)
  expect_identical(m$log$country_name, "Testland")

  # The CSV artifact was written with the same row.
  art <- carbon_read(dir, "mylog.csv")
  expect_equal(nrow(art), 1)
  expect_equal(art$emissions_total, 0.5)
})

# 6. When stop_task() yields no data, the log falls back to a "none" row with NA
#    emissions but still captures the run() value and wall time.
test_that("carbon_measure() falls back to a 'none' row when stop_task() fails", {
  dir <- file.path(tempdir(), "measure-none")
  bad <- list(
    output_dir = dir,
    start_task = function() NULL,
    stop_task  = function() stop("py error")
  )
  m <- tidycarbon:::carbon_measure(
    run = function() 1 + 1,
    tracker = bad,
    label = "add",
    task_id = "id-1",
    output_dir = dir,
    output_file = "emissions.csv"
  )

  expect_equal(m$result, 2)
  expect_equal(nrow(m$log), 1)
  expect_identical(m$log$output_source, "none")
  expect_true(is.na(m$log$emissions_total))
  expect_true(is.na(m$log$energy_consumed))
})

# 7. The CSV is not load-bearing: an unwritable destination is swallowed and the
#    measurement (result + in-memory log) is returned intact.
test_that("carbon_measure() succeeds even when the CSV artifact cannot be written", {
  bad_dir <- "/proc/nonexistent/cannot/write"
  m <- tidycarbon:::carbon_measure(
    run = function() 42,
    tracker = fake_tracker(output_dir = bad_dir, emissions = 0.0001),
    label = "x",
    task_id = "id-3",
    output_dir = bad_dir,
    output_file = "emissions.csv"
  )

  expect_equal(m$result, 42)
  expect_equal(m$log$emissions_total, 0.0001)
  expect_false(file.exists(file.path(bad_dir, "emissions.csv")))
})

# 8. Repeated measurements append to the artifact rather than overwriting it.
test_that("carbon_measure() appends rows to the CSV artifact across calls", {
  dir <- file.path(tempdir(), "measure-accum")
  unlink(dir, recursive = TRUE)
  ft <- fake_tracker(output_dir = dir, emissions = 0.2)

  tidycarbon:::carbon_measure(function() 1, ft, "a", "id-a", dir, "emissions.csv")
  tidycarbon:::carbon_measure(function() 2, ft, "b", "id-b", dir, "emissions.csv")

  art <- carbon_read(dir, "emissions.csv")
  expect_equal(nrow(art), 2)
  expect_identical(art$label, c("a", "b"))
})
