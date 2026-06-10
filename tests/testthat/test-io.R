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
