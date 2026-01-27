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

#' Get the last row of CodeCarbon emissions CSV
#'
#' @param output_dir Directory containing the emissions CSV.
#' @param output_file CSV filename (default "emissions.csv").
#' @return A 1-row tibble or NULL if empty/missing.
#' @keywords internal
carbon_last_row <- function(output_dir, output_file = "emissions.csv") {
  df <- carbon_read(output_dir, output_file)
  if (nrow(df) == 0) return(NULL)
  df[nrow(df), , drop = FALSE]
}
