
# The global tracker, via simple tracker_start and tracker_stop can wrap around
# whatever your R code is without needing any additional changes. carbon_init()
# registers the tracker as the session default, and tracker_stop() logs the
# session as one uniform row in emissions_r.csv (the same schema as
# carbon_step()/carbon_run()/carbon_track()).

#library(tidycarbon)

tidycarbon::carbon_init(project_name = "package_test")
print("Tracker initiated")

# Start the tracker
tidycarbon::tracker_start()
print("Started Tracker")

# Provide whatever R code
library(magrittr)

iris %>%
  dplyr::select(1) %>%
  dplyr::pull() %>%
  sum()

# Provide a more advanced NLP example

# Stop the tracker; returns the rich one-row emissions tibble
session_log <- tidycarbon::tracker_stop(label = "iris session")
print(session_log)
