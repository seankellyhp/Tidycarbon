#' Read CodeCarbon emissions CSV
#'
#' @param output_dir Directory containing the emissions CSV.
#' @param output_file CSV filename (default "emissions.csv").
#' @return A tibble of CodeCarbon records (empty tibble if file missing).
#' @export
carbon_read <- function(output_dir, output_file = "emissions.csv") {
  path <- file.path(output_dir, output_file)
  if (!file.exists(path)) {
    return(tibble::tibble())
  }
  readr::read_csv(path, show_col_types = FALSE) |>
    tibble::as_tibble()
}
