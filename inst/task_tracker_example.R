
# carbon_track() and carbon_track_all() wrap individual function calls in a
# CodeCarbon task window. Each call yields one rich emissions row (the same
# shape as carbon_step()'s log, plus `args`/`result` list-columns) and appends
# it to the emissions CSV with a unique task id.

#library(tidycarbon)

# Initiate the tracker; it is registered as the session default, so the
# carbon_track* calls below need no explicit tracker argument.
carbon_init(project_name = "package_test_task")
print("Tracker initiated")

# Write Example Functions
square <- function(x) x^2

count_skip_n <- function(n) {
  for (i in 1:100) {
    if (i %% n == 0) next
  }
  sprintf("Success: %s.", n)
}

## Implement the Tracker

# Track a single function call
carbon_track(square, 2)

# Track multiple function calls (label is optional per spec)
tasks <- list(
  list(fun = count_skip_n, args = list(n = 3), label = "count_skip_n(3)"),
  list(fun = count_skip_n, args = list(n = 4), label = "count_skip_n(4)"),
  list(fun = square,       args = list(x = 2), label = "square(2)"),
  list(fun = square,       args = list(x = 3), label = "square(3)")
)

result_df <- carbon_track_all(tasks)
