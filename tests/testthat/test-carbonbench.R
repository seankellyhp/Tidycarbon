# 10. The carbonbench S3 autoplot method dispatches and validates its metric.
#     (carbon_bench() itself needs a live tracker; the plotting contract does not.)
test_that("autoplot.carbonbench() dispatches via S3 and checks the metric arg", {
  b <- structure(
    tibble::tibble(
      expr = c("a", "b"),
      duration = c(1, 2),
      emissions_total = c(0.1, 0.2),
      energy_consumed = c(1, 2)
    ),
    class = c("carbonbench", class(tibble::tibble()))
  )

  p <- ggplot2::autoplot(b, metric = "emissions_total")
  expect_s3_class(p, "ggplot")

  # match.arg() rejects unknown metrics.
  expect_error(ggplot2::autoplot(b, metric = "nonsense"))

  # carbon_bench() guards against unnamed / single expressions up front.
  expect_error(carbon_bench(sum(1:10), times = 1), "two or more named")
})
