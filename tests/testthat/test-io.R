# 2. carbon_read() tolerates a missing file and round-trips a real CSV.
test_that("carbon_read() returns an empty tibble for a missing file and reads a present one", {
  missing_dir <- file.path(tempdir(), "carbon-read-missing")
  empty <- carbon_read(missing_dir, "nope.csv")
  expect_s3_class(empty, "tbl_df")
  expect_equal(nrow(empty), 0)

  dir <- write_emissions_csv()
  df <- carbon_read(dir, "emissions.csv")
  expect_s3_class(df, "tbl_df")
  expect_equal(nrow(df), 1)
  expect_equal(df$energy_consumed, 2)
})

# 3. carbon_last_row() is the internal tail reader used by carbon_measure().
test_that("carbon_last_row() is NULL when empty and the final row otherwise", {
  missing_dir <- file.path(tempdir(), "carbon-last-missing")
  expect_null(tidycarbon:::carbon_last_row(missing_dir, "nope.csv"))

  dir <- write_emissions_csv()
  last <- tidycarbon:::carbon_last_row(dir, "emissions.csv")
  expect_equal(nrow(last), 1)
  expect_equal(last$duration, 1.5)
})
