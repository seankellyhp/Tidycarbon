
# Next step
tracker <- carbon_init(project_name = "package_test")

library(magrittr)

iris %>%
  carbon_track() %>%
  dplyr::select(1) %>%
  dplyr::pull() %>%
  dplyr::count() %>%
  tracker_stop()
