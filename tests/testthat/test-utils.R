# 1. %||% is the hand-rolled internal null-coalescing operator (R/utils.R).
test_that("%||% returns the fallback only for NULL", {
  `%||%` <- tidycarbon:::`%||%`
  expect_identical(NULL %||% "fallback", "fallback")
  expect_identical(1L %||% "fallback", 1L)
  expect_identical(NA %||% "fallback", NA)            # NA is not NULL
  expect_identical(list() %||% "fallback", list())    # empty is not NULL
})
