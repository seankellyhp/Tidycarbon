#' Read the tidycarbon emissions CSV
#'
#' @param output_dir Directory containing the emissions CSV.
#' @param output_file CSV filename (default "emissions_r.csv").
#' @return A tibble of emissions records (empty tibble if file missing).
#' @export
carbon_read <- function(output_dir, output_file = "emissions_r.csv") {
  path <- file.path(output_dir, output_file)
  if (!file.exists(path)) {
    return(tibble::tibble())
  }
  readr::read_csv(path, show_col_types = FALSE) |>
    tibble::as_tibble()
}
