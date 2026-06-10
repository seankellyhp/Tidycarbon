#' Track emissions for a whole pipeline/expression
#'
#' Runs an expression in a single CodeCarbon task window
#' (`tracker$start_task()` / `tracker$stop_task()`). Emissions data is returned
#' in memory and also appended to a CSV as a best-effort artifact.
#'
#' @param expr An expression to evaluate (captured).
#' @param tracker A CodeCarbon tracker. Defaults to the session tracker
#'   registered by [carbon_init()].
#' @param label Optional label for the run.
#' @param task_id Optional UUID string.
#' @param output_dir Directory for the CSV artifact. If NULL, falls back to
#'   `tracker$output_dir` then the value registered by [carbon_init()]; if none
#'   resolves, the artifact is skipped.
#' @param output_file CSV filename for the artifact. If NULL, falls back to the
#'   value registered by [carbon_init()] (default "emissions_r.csv").
#'
#' @return A list with:
#'   - `result`: the evaluated expression
#'   - `log`: a rich one-row tibble of in-memory emissions data
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
