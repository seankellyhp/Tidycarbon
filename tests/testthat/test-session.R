# tracker_start()/tracker_stop() (the global session API) now log to the same
# uniform schema and emissions_r.csv artifact as carbon_step()/carbon_run()/
# carbon_track(). The rich row comes from tracker$final_emissions_data.

test_that("tracker_stop() returns the uniform row and appends it to the artifact", {
  dir <- file.path(tempdir(), "session-uniform")
  unlink(dir, recursive = TRUE)
  ft <- fake_session_tracker(output_dir = dir, emissions = 0.7)

  tracker_start(ft)
  log <- tracker_stop(ft, label = "my session")

  expect_equal(nrow(log), 1)
  expect_identical(log$label, "my session")
  expect_equal(log$emissions_total, 0.7)
  expect_true(log$wall_time_sec >= 0)
  # Same uniform schema as the other measurement functions.
  expect_identical(
    names(log),
    names(tidycarbon:::carbon_emissions_row(fake_emissions(), "x", "y", 0, "z"))
  )

  # The row landed in the shared default artifact.
  art <- carbon_read(dir, "emissions_r.csv")
  expect_equal(nrow(art), 1)
  expect_identical(art$label, "my session")
})

test_that("session and step rows share one artifact without schema collision", {
  dir <- file.path(tempdir(), "session-mixed")
  unlink(dir, recursive = TRUE)

  out <- carbon_step(1:10, sum, tracker = fake_tracker(output_dir = dir))
  tracker_stop(fake_session_tracker(output_dir = dir), label = "session")

  art <- carbon_read(dir, "emissions_r.csv")
  expect_equal(nrow(art), 2)  # appended, not overwritten
  expect_identical(art$label, c("sum", "session"))
})

test_that("tracker_stop() degrades to the stop() scalar when final_emissions_data is missing", {
  dir <- file.path(tempdir(), "session-fallback")
  unlink(dir, recursive = TRUE)
  ft <- fake_session_tracker(output_dir = dir, emissions = 0.2,
                             final_emissions_data = NULL)

  log <- tracker_stop(ft)

  expect_equal(log$emissions_total, 0.2)
  expect_true(is.na(log$duration))
  expect_identical(log$output_source, "none")
})

test_that("tracker_start()/tracker_stop() use the session default tracker", {
  the <- tidycarbon:::.the

  # Snapshot and restore so we don't leak state into other tests.
  old <- list(
    tracker = the$tracker, output_dir = the$output_dir,
    output_file = the$output_file
  )
  withr::defer({
    the$tracker <- old$tracker
    the$output_dir <- old$output_dir
    the$output_file <- old$output_file
  })

  the$tracker <- NULL
  expect_error(tracker_start(), "No active tracker")
  expect_error(tracker_stop(), "No active tracker")

  dir <- file.path(tempdir(), "session-registry")
  unlink(dir, recursive = TRUE)
  the$tracker     <- fake_session_tracker(output_dir = dir)
  the$output_dir  <- dir
  the$output_file <- "emissions_r.csv"

  tracker_start()
  log <- tracker_stop()
  expect_identical(log$label, "session")
  expect_equal(nrow(carbon_read(dir, "emissions_r.csv")), 1)
})
