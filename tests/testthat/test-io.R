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

test_that("carbon_read() defaults to the location registered by carbon_init()", {
  the <- tidycarbon:::.the
  old <- mget(c("output_dir", "output_file"), envir = the, ifnotfound = list(NULL))
  withr::defer({ the$output_dir <- old$output_dir; the$output_file <- old$output_file })

  dir <- write_emissions_csv(file = "mine.csv")
  the$output_dir  <- dir
  the$output_file <- "mine.csv"
  expect_equal(nrow(carbon_read()), 1)

  # Unregistered: the working directory and emissions_r.csv.
  the$output_dir <- NULL
  the$output_file <- NULL
  withr::local_dir(write_emissions_csv(file = "emissions_r.csv"))
  expect_equal(nrow(carbon_read()), 1)
})
