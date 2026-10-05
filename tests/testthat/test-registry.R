# 4. The .the session registry accessors (R/zzz.R) and the missing-tracker abort.
test_that("carbon_default_* read the registry and abort when no tracker is set", {
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

  # Unset defaults: dir is NULL, file falls back to "emissions_r.csv".
  expect_null(tidycarbon:::carbon_default_output_dir())
  expect_identical(tidycarbon:::carbon_default_output_file(), "emissions_r.csv")
  expect_error(tidycarbon:::carbon_default_tracker(), "No active tracker")

  # Once registered, the accessors echo the stored values.
  the$tracker <- fake_tracker()
  the$output_dir <- "/some/dir"
  the$output_file <- "mylog.csv"
  expect_identical(tidycarbon:::carbon_default_output_dir(), "/some/dir")
  expect_identical(tidycarbon:::carbon_default_output_file(), "mylog.csv")
  expect_identical(tidycarbon:::carbon_default_tracker(), the$tracker)
})
