# Package-internal state: default tracker registered by carbon_init().
.the <- new.env(parent = emptyenv())

#' Get the default tracker registered by carbon_init()
#'
#' @return The CodeCarbon tracker registered by the most recent
#'   [carbon_init()] call.
#' @keywords internal
carbon_default_tracker <- function() {
  .the$tracker %||% rlang::abort("No active tracker. Call carbon_init() first.")
}

#' Default output directory registered by carbon_init()
#' @return The registered output directory, or NULL.
#' @keywords internal
carbon_default_output_dir <- function() .the$output_dir

#' Default output file registered by carbon_init()
#' @return The registered output file name, or "emissions_r.csv".
#' @keywords internal
carbon_default_output_file <- function() .the$output_file %||% "emissions_r.csv"
