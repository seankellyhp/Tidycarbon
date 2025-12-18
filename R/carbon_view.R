#' @title Launch the carbon_view shiny app
#' @name carbon_view
#' @description
#' \code{carbon_view} Launches the app to analyze code carbon data with multiples techniques.

carbon_view <- function(use_browser = TRUE) {
  appDir <- system.file("app", package = "tidycarbon")
  if (appDir == "") {
    stop("Could not find directory. Try re-installing `tidycarbon`.",
         call. = FALSE)
  }

  if (use_browser == TRUE)
    shiny::runApp(appDir, display.mode = "normal",
                  launch.browser = TRUE)
  else
    shiny::runApp(appDir, display.mode = "normal")

}
