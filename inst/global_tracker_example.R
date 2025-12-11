
# The global tracker, via simple tracker_start and tracker_stop can wrap around
# whatever your R code is without needing any additional changes.

#library(tidycarbon)

tracker <- tidycarbon::carbon_init(project_name = "package_test")
print("Tracker initiated")

# Start the tracker
tidycarbon::tracker_start(tracker)
print("Started Tracker")

# Provide whatever R code
library(magrittr)

iris %>%
  dplyr::select(1) %>%
  dplyr::pull() %>%
  sum()

# Provide a more advanced NLP example

# Stop the tracker
tidycarbon::tracker_stop(tracker)
print("Stopped Tracker")
