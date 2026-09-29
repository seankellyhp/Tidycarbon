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

#' Collect provider-side logs from a pipeline object
#'
#' `carbon_step(chat = ...)` stores the per-request provider-side estimate of
#' each step as an attribute on the returned object. Summarise it with
#' [carbon_provider_summary()]; never add it to [carbon_collect()]'s figures.
#'
#' @param x An object returned by `carbon_step()`.
#' @return A tibble (possibly empty).
#' @export
carbon_collect_provider <- function(x) {
  attr(x, "provider_log") %||% tibble::tibble()
}

#' Track emissions for one pipeline step
#'
#' Wraps a single function call `.f(.data, ...)` with `tracker$start()` and
#' `tracker$stop()`, then reads the latest row from CodeCarbon's emissions CSV.
#'
#' This is robust across CodeCarbon versions where `tracker$stop()` returns only
#' a numeric (kgCO2) rather than a full data object.
#'
#' @param .data Input data (pipe LHS).
#' @param .f Function to apply to `.data` (must accept `.data` as first arg).
#' @param ... Passed to `.f`.
#' @param tracker A CodeCarbon tracker from `carbon_init_pipe()`.
#' @param label Optional human-readable label for the step.
#' @param task_id Optional UUID string for joining/identification.
#' @param output_dir Directory containing the emissions CSV. If NULL, attempts to
#'   read from `tracker$output_dir`.
#' @param output_file CSV filename (default "emissions.csv").
#' @param chat Optional ellmer `Chat` used inside the tracked code. Its new
#'   requests are estimated with [carbon_provider()]; see `@return`.
#'
#' @return The transformed object (result of `.f(.data, ...)`) with a
#'   `carbon_log` attribute (tibble) and, when `chat` is given, a
#'   `provider_log` attribute accumulating the per-request provider-side
#'   estimate of each step (see [carbon_collect_provider()]).
#' @export
carbon_step <- function(.data,
                        .f,
                        ...,
                        tracker,
                        label = NULL,
                        task_id = uuid::UUIDgenerate(),
                        output_dir = NULL,
                        output_file = "emissions.csv",
                        chat = NULL) {

  stopifnot(is.function(.f))
  if (is.null(label)) label <- deparse(substitute(.f))

  # Run the upstream steps now: `.data` is a lazy promise, and forcing it inside
  # this step's tracking window would nest the previous step's work in it.
  force(.data)

  if (is.null(output_dir)) {
    output_dir <- tryCatch(tracker$output_dir, error = function(e) NULL)
  }
  if (is.null(output_dir)) {
    rlang::abort("output_dir is required (or tracker must expose tracker$output_dir).")
  }

  before_n <- nrow(carbon_read(output_dir, output_file))
  turns_before <- chat_turn_count(chat)

  tryCatch(tracker$start(), error = function(e) NULL)

  t0 <- Sys.time()
  error_obj <- NULL
  out <- tryCatch(
    .f(.data, ...),
    error = function(e) { error_obj <<- e; NULL }
  )
  wall_time_sec <- as.numeric(difftime(Sys.time(), t0, units = "secs"))

  emissions_total <- tryCatch(as.numeric(tracker$stop()), error = function(e) NA_real_)

  if (!is.null(error_obj)) stop(error_obj)

  after_df <- carbon_read(output_dir, output_file)
  after_n <- nrow(after_df)

  last <- if (after_n > before_n) {
    after_df[after_n, , drop = FALSE]
  } else {
    carbon_last_row(output_dir, output_file)
  }

  log_row <- if (is.null(last) || nrow(last) == 0) {
    tibble::tibble(
      task_id = task_id,
      label = label,
      timestamp = as.character(Sys.time()),
      wall_time_sec = wall_time_sec,
      emissions_total = emissions_total,
      duration = NA_real_,
      energy_consumed = NA_real_,
      cpu_energy = NA_real_,
      ram_energy = NA_real_,
      gpu_energy = NA_real_,
      output_source = "none"
    )
  } else {
    tibble::tibble(
      task_id = task_id,
      label = label,
      timestamp = as.character((last$timestamp %||% Sys.time())),
      wall_time_sec = wall_time_sec,
      emissions_total = emissions_total,
      duration = as.numeric(last$duration %||% NA_real_),
      energy_consumed = as.numeric(last$energy_consumed %||% NA_real_),
      cpu_energy = as.numeric(last$cpu_energy %||% NA_real_),
      ram_energy = as.numeric(last$ram_energy %||% NA_real_),
      gpu_energy = as.numeric(last$gpu_energy %||% NA_real_),
      output_source = "emissions.csv"
    )
  }

  prev <- attr(.data, "carbon_log")
  attr(out, "carbon_log") <- dplyr::bind_rows(prev, log_row)

  prev_provider <- attr(.data, "provider_log")
  if (!is.null(chat)) {
    step_provider <- provider_for_chat(chat, turns_before, wall_time_sec)
    if (!is.null(step_provider)) {
      step_provider <- tibble::add_column(step_provider, task_id = task_id, label = label, .before = 1)
    }
    prev_provider <- dplyr::bind_rows(prev_provider, step_provider)
  }
  attr(out, "provider_log") <- prev_provider

  out
}
