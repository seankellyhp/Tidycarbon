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
#    emissions, keeps the run() value and wall time, and says so with a warning.
test_that("carbon_measure() warns and falls back to a 'none' row when stop_task() fails", {
  dir <- file.path(tempdir(), "measure-none")
  measure <- function(stop_task) {
    tidycarbon:::carbon_measure(
      run = function() 1 + 1,
      tracker = list(output_dir = dir, start_task = function() NULL,
                     stop_task = stop_task),
      label = "add",
      task_id = "id-1",
      output_dir = dir,
      output_file = "emissions.csv"
    )
  }

  expect_warning(m <- measure(function() stop("py error")), "py error")
  expect_equal(m$result, 2)
  expect_equal(nrow(m$log), 1)
  expect_identical(m$log$output_source, "none")
  expect_true(is.na(m$log$emissions_total))
  expect_true(is.na(m$log$energy_consumed))

  # CodeCarbon returns None, not an error, when it has no task to close.
  expect_warning(m <- measure(function() NULL), "returned no data")
  expect_identical(m$log$output_source, "none")
})

# 6b. A tracker that cannot open a task aborts before run() is called.
test_that("carbon_measure() aborts when the task cannot be started", {
  ran <- FALSE
  bad <- list(
    start_task = function() stop("no tracker"),
    stop_task  = function() NULL
  )
  expect_error(
    tidycarbon:::carbon_measure(
      run = function() ran <<- TRUE,
      tracker = bad, label = "add", task_id = "id-1",
      output_dir = NULL, output_file = "emissions.csv"
    ),
    "no tracker"
  )
  expect_false(ran)
})

# 7. The CSV is not load-bearing: an unwritable destination only warns, and the
#    measurement (result + in-memory log) is returned intact.
test_that("carbon_measure() succeeds even when the CSV artifact cannot be written", {
  bad_dir <- "/proc/nonexistent/cannot/write"
  expect_warning(
    m <- tidycarbon:::carbon_measure(
      run = function() 42,
      tracker = fake_tracker(output_dir = bad_dir, emissions = 0.0001),
      label = "x",
      task_id = "id-3",
      output_dir = bad_dir,
      output_file = "emissions.csv"
    ),
    "were not logged"
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

# 9. A file with other columns is the user's data: it is never overwritten.
test_that("carbon_measure() leaves an artifact with other columns untouched", {
  dir <- file.path(tempdir(), "measure-foreign")
  unlink(dir, recursive = TRUE)
  dir.create(dir)
  path <- file.path(dir, "emissions.csv")
  writeLines(c("a,b", "1,2", "3,4"), path)
  ft <- fake_tracker(output_dir = dir, emissions = 0.3)

  expect_warning(
    m <- tidycarbon:::carbon_measure(function() 1, ft, "a", "id-a", dir, "emissions.csv"),
    "different columns"
  )
  expect_equal(m$log$emissions_total, 0.3)
  expect_identical(readLines(path), c("a,b", "1,2", "3,4"))

  # Warned once per file, and still untouched on the next measurement.
  expect_no_warning(
    tidycarbon:::carbon_measure(function() 2, ft, "b", "id-b", dir, "emissions.csv")
  )
  expect_identical(readLines(path), c("a,b", "1,2", "3,4"))
})

# 10. An empty file has no columns to disagree with, so it is started afresh.
test_that("carbon_measure() writes a header into an empty artifact", {
  dir <- file.path(tempdir(), "measure-empty")
  unlink(dir, recursive = TRUE)
  dir.create(dir)
  file.create(file.path(dir, "emissions.csv"))
  ft <- fake_tracker(output_dir = dir)

  tidycarbon:::carbon_measure(function() 1, ft, "a", "id-a", dir, "emissions.csv")
  tidycarbon:::carbon_measure(function() 2, ft, "b", "id-b", dir, "emissions.csv")

  expect_identical(carbon_read(dir, "emissions.csv")$label, c("a", "b"))
})
