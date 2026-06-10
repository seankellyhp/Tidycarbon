#' Collect step logs from a pipeline object
#'
#' `carbon_step()` stores logs as an attribute on the returned object.
#'
#' @param x An object returned by `carbon_step()`.
#' @return A tibble (possibly empty).
#' @export
carbon_collect <- function(x) {
  attr(x, "carbon_log") %||% tibble::tibble()
}

#' Track emissions for one pipeline step
#'
#' Wraps a single pipeline step with `tracker$start()` and `tracker$stop()`,
#' then reads the latest row from CodeCarbon's emissions CSV.
#'
#' `.f` can be supplied two ways:
#' - **Call form** (slide syntax): `carbon_step(x, tokens_ngrams(n = 1:3))`.
#'   The unevaluated call has `.data` inserted as its first argument and is
#'   evaluated in the caller's environment.
#' - **Function/symbol form**: `carbon_step(x, tokens, remove_punct = TRUE)`,
#'   `carbon_step(x, \(d) head(d, 3))`, `carbon_step(x, quanteda::tokens)`.
#'   The function is applied as `.f(.data, ...)`.
#'
#' This is robust across CodeCarbon versions where `tracker$stop()` returns only
#' a numeric (kgCO2) rather than a full data object.
#'
#' @param .data Input data (pipe LHS).
#' @param .f A function, or an unevaluated call whose first argument slot will
#'   receive `.data`.
#' @param ... Passed to `.f` in the function/symbol form (ignored, with a
#'   warning, in the call form --- supply arguments inside the call instead).
#' @param tracker A CodeCarbon tracker. Defaults to the session tracker
#'   registered by [carbon_init()].
#' @param label Optional human-readable label for the step. Defaults to the
#'   deparsed `.f`.
#' @param task_id Optional UUID string for joining/identification.
#' @param output_dir Directory containing the emissions CSV. If NULL, falls back
#'   to `tracker$output_dir` then the value registered by [carbon_init()].
#' @param output_file CSV filename. If NULL, falls back to the value registered
#'   by [carbon_init()] (default "emissions.csv").
#'
#' @return The transformed object with a `carbon_log` attribute (tibble).
#' @examples
#' \dontrun{
#' carbon_init(project_name = "demo")
#' out <- (1:10) |> carbon_step(sqrt()) |> carbon_step(sum())
#' carbon_collect(out)
#' }
#' @export
carbon_step <- function(.data,
                        .f,
                        ...,
                        tracker = carbon_default_tracker(),
                        label = NULL,
                        task_id = uuid::UUIDgenerate(),
                        output_dir = NULL,
                        output_file = NULL) {

  expr   <- substitute(.f)
  caller <- parent.frame()

  # Call form: carbon_step(x, tokens_ngrams(n = 1:3)).
  # Anonymous functions (`function(x) ...`, `\(x) ...`) parse as calls with
  # head `function`; namespaced bare functions (`quanteda::tokens`) parse as
  # calls with head `::`/`:::`. All three must take the function form.
  call_form <- is.call(expr) &&
    !identical(expr[[1L]], quote(`function`)) &&
    !identical(expr[[1L]], quote(`::`)) &&
    !identical(expr[[1L]], quote(`:::`))

  if (is.null(label)) label <- deparse1(expr)

  if (call_form) {
    if (...length() > 0) {
      rlang::warn(
        "Arguments in `...` are ignored in call form; put them inside the call."
      )
    }
    new_call <- as.call(append(as.list(expr), list(quote(.data)), after = 1L))
    eval_env <- new.env(parent = caller)
    assign(".data", .data, envir = eval_env)
    run <- function() eval(new_call, eval_env)
  } else {
    .f <- match.fun(.f)        # forces the promise; symbol & function forms
    run <- function() .f(.data, ...)
  }

  m <- carbon_measure(run, tracker, label, task_id, output_dir, output_file)

  out <- m$result
  prev <- attr(.data, "carbon_log")
  attr(out, "carbon_log") <- dplyr::bind_rows(prev, m$log)

  out
}
