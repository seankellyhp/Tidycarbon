#' Read the tidycarbon emissions CSV
#'
#' @param output_dir Directory containing the emissions CSV. Defaults to the
#'   one registered by [carbon_init()], else the working directory.
#' @param output_file CSV filename. Defaults to the one registered by
#'   [carbon_init()], else "emissions_r.csv". A remote tracker logs to its own
#'   file ("emissions_remote.csv" by default, see [carbon_init_remote()]).
#' @return A tibble of emissions records (empty tibble if file missing).
#' @export
carbon_read <- function(output_dir = NULL, output_file = NULL) {
  output_dir  <- output_dir %||% carbon_default_output_dir() %||% "."
  output_file <- output_file %||% carbon_default_output_file()
  path <- file.path(output_dir, output_file)
  if (!file.exists(path)) {
    return(tibble::tibble())
  }
  readr::read_csv(path, show_col_types = FALSE) |>
    tibble::as_tibble()
}
