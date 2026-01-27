#' Internal null-coalescing operator
#' @keywords internal
`%||%` <- function(a, b) if (is.null(a)) b else a
