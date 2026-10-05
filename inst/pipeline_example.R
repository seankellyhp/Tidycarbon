
# Per-step pipeline tracking (new pipe-call syntax).
# carbon_init() registers the tracker as the session default, so each
# carbon_step() needs neither tracker= nor output_dir=. The step call is passed
# directly and the piped data fills its first argument slot. carbon_collect()
# pulls the accumulated per-step log.

library(tidycarbon)
library(dplyr)

carbon_init(project_name = "package_test_pipeline")

out <- iris |>
  carbon_step(select(Sepal.Length)) |>
  carbon_step(pull()) |>
  carbon_step(sum())

carbon_collect(out)
