# carbon_step() wraps one pipeline step and accumulates a `carbon_log` attr.

# 7. Both .f forms work, logs chain, and carbon_collect() reads them back.
test_that("carbon_step() handles call + function forms, chains, and collects", {
  ft <- fake_tracker()

  # carbon_collect() on a bare object is an empty tibble.
  expect_equal(nrow(carbon_collect(1:10)), 0)

  # Call form (slide syntax) then function/symbol form, chained.
  out <- (1:10) |>
    carbon_step(sqrt(), tracker = ft) |>
    carbon_step(sum(), tracker = ft)
  expect_equal(as.numeric(out), sum(sqrt(1:10)))

  log <- carbon_collect(out)
  expect_equal(nrow(log), 2)
  expect_identical(log$label[1], "sqrt()")
  expect_identical(log$label[2], "sum()")

  # Function form forwards `...` to .f(.data, ...).
  expect_identical(
    as.integer(carbon_step(1:10, head, n = 3, tracker = ft)),
    1:3
  )
})

# 8. Errors raised inside the step propagate, and `...` in call form warns.
test_that("carbon_step() propagates step errors and warns about ignored ... in call form", {
  ft <- fake_tracker()

  msg <- tryCatch(
    carbon_step(1:10, \(d) stop("boom"), tracker = ft),
    error = conditionMessage
  )
  expect_identical(msg, "boom")

  expect_warning(
    carbon_step(1:10, sum(), na.rm = TRUE, tracker = ft),
    "ignored in call form"
  )
})
