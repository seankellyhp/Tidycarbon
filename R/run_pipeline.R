#' Track emissions for a whole pipeline/expression
#'
#' Runs an expression under a single `tracker$start()` / `tracker$stop()` window.
#'
#' @param expr An expression to evaluate (captured).
#' @param tracker A CodeCarbon tracker. Defaults to the session tracker
#'   registered by [carbon_init()].
#' @param label Optional label for the run.
#' @param task_id Optional UUID string.
#' @param output_dir Directory containing the emissions CSV. If NULL, falls back
#'   to `tracker$output_dir` then the value registered by [carbon_init()].
#' @param output_file CSV filename. If NULL, falls back to the value registered
#'   by [carbon_init()] (default "emissions.csv").
#'
#' @return A list with:
#'   - `result`: the evaluated expression
#'   - `log`: a 1-row tibble with emissions/time and CSV-derived fields
#' @export
carbon_run <- function(expr,
                       tracker = carbon_default_tracker(),
                       label = "pipeline",
                       task_id = uuid::UUIDgenerate(),
                       output_dir = NULL,
                       output_file = NULL) {

  expr_q <- substitute(expr)
  caller <- parent.frame()
  run <- function() eval(expr_q, envir = caller)

  m <- carbon_measure(run, tracker, label, task_id, output_dir, output_file)
  list(result = m$result, log = m$log)
}
