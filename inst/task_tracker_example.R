
# The task tracker, via carbon_track and carbon_track_all are used to wrap
# around particular functions and they will print within the same emissions csv
# with unique ids.

#library(tidycarbon)

# Initiate the tracker
tracker <- carbon_init(project_name = "package_test_task")
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

# Track a single function
carbon_track(square, 2, tracker = tracker)

# Track multiple functions
tasks <- list(
  list(fun = count_skip_n, args = list(n = 3)),
  list(fun = count_skip_n, args = list(n = 4)),
  list(fun = square,       args = list(x = 2)),
  list(fun = square,       args = list(x = 3))
)

result_df <- carbon_track_all(tasks, tracker = tracker)






