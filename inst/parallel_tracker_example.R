

library(tidycarbon)

tracker <- carbon_init(project_name = "package_test")
print("Tracker initiated")

#carbon_share(uid) # jvdfjjdsncdshskcnsfansafawnka

# Start the tracker
tracker_start(tracker)
print("Started Tracker")

library(foreach)
# How many times will the loop run
n_iterations <- 100000
# To save the results
results <- list()

# Use foreach and %dopar% to run the loop in parallel
results <- foreach(i = 1:n_iterations) %dopar% {
  # Store the results
  results[i] <- i^2
}

tracker_stop(tracker)

