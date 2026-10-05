# 9. carbon_run() must evaluate the captured expression in the CALLER's frame,
#    not the delegated helper's frame (the parent.frame() risk noted in CLAUDE.md).
test_that("carbon_run() evaluates the expression in the caller environment", {
  local_var <- 21
  r <- carbon_run(local_var * 2, tracker = fake_tracker(), label = "lv")

  expect_equal(r$result, 42)
  expect_identical(r$log$label, "lv")
  expect_equal(nrow(r$log), 1)
})
