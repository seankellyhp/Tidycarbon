# carbon_track()/carbon_track_all() are single-shot measurement wrappers built
# on the same carbon_measure() core as carbon_step()/carbon_run(): registry
# default tracker, guarded task window, rich in-memory row, best-effort CSV.

test_that("carbon_track() returns the rich log row plus args/result columns", {
  dir <- file.path(tempdir(), "track-one")
  unlink(dir, recursive = TRUE)

  row <- carbon_track(sum, 1:10, tracker = fake_tracker(output_dir = dir,
                                                        emissions = 0.3))

  expect_equal(nrow(row), 1)
  expect_identical(row$label, "sum")
  expect_identical(row$result[[1]], 55L)
  expect_identical(row$args[[1]], list(1:10))
  # Shares the carbon_step() log shape (rich subset spot-checks).
  expect_true(all(
    c("task_id", "label", "timestamp", "wall_time_sec", "emissions_total",
      "energy_consumed", "output_source", "water_consumed", "country_name")
    %in% names(row)
  ))
  expect_equal(row$emissions_total, 0.3)

  # The CSV artifact was written (without the args/result list-columns).
  art <- carbon_read(dir, "emissions_r.csv")
  expect_equal(nrow(art), 1)
  expect_false(any(c("args", "result") %in% names(art)))
})

test_that("carbon_track() propagates errors from fun", {
  expect_error(
    carbon_track(function() stop("boom"), tracker = fake_tracker()),
    "boom"
  )
})

test_that("carbon_track() uses the session default tracker from carbon_init()", {
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
  the$output_dir <- NULL
  the$output_file <- NULL
  expect_error(carbon_track(sum, 1:3), "No active tracker")

  dir <- file.path(tempdir(), "track-registry")
  unlink(dir, recursive = TRUE)
  the$tracker     <- fake_tracker(output_dir = dir)
  the$output_dir  <- dir
  the$output_file <- "emissions.csv"

  row <- carbon_track(sum, 1:3)
  expect_identical(row$result[[1]], 6L)
  expect_equal(nrow(carbon_read(dir, "emissions.csv")), 1)
})

test_that("carbon_track_all() maps specs and honors optional labels", {
  dir <- file.path(tempdir(), "track-all")
  unlink(dir, recursive = TRUE)
  ft <- fake_tracker(output_dir = dir)

  out <- carbon_track_all(
    list(
      list(fun = sum,  args = list(1:3), label = "sum3"),
      list(fun = head, args = list(letters, n = 2))
    ),
    tracker = ft
  )

  expect_equal(nrow(out), 2)
  expect_identical(out$label[1], "sum3")
  expect_identical(out$result[[1]], 6L)
  expect_identical(out$result[[2]], c("a", "b"))
  # Both rows landed in the shared artifact.
  expect_equal(nrow(carbon_read(dir, "emissions_r.csv")), 2)
})
