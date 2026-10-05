#' Provider-side inference impacts and token accounting
#'
#' CodeCarbon measures the electricity *this machine* draws. When R code calls a
#' hosted LLM, the inference runs in the provider's datacenter, which CodeCarbon
#' cannot see. These functions estimate that provider-side impact with
#' [EcoLogits](https://ecologits.ai) from the billed token usage of each request.
#'
#' To track R code, create a remote tracker with [carbon_init_remote()]
#' and use it wherever a CodeCarbon tracker goes.
#'
#' Underneath, everything starts from a *calls* table, one row per billed
#' request (see [carbon_calls()]), built from an ellmer chat
#' ([calls_from_ellmer()]), a Claude Code session transcript
#' ([calls_from_transcript()]) or by hand.
#'
#' Caveats, carried into every result:
#' * **Only output tokens and latency enter the EcoLogits model.** Input and
#'   cache tokens contribute nothing, so the estimate prices output
#'   generation, not "the impact of the conversation".
#' * **Figures are ranges** (`*_min` / `*_max`) whenever the provider does not
#'   publish its model's architecture or its datacenter's efficiency.
#'   `*_mean` is the midpoint of the range, not a measured average.
#' * **Latency can only lower the estimate.** An unknown latency (`NA`) leaves
#'   the modelled generation time uncapped.
#' * **Which models can be estimated is EcoLogits' decision.** The model name
#'   is looked up in its registry as the client recorded it. One it has not
#'   registered (often a model newer than the installed release) is left out,
#'   with `modelled = FALSE` and the EcoLogits error code in `error`.
#' * **Never add these figures to CodeCarbon's**, and never divide local energy
#'   by tokens. Different scopes, different methods.
#'
#' @name provider-impacts
NULL

.provider_env <- new.env(parent = emptyenv())

#' Load the EcoLogits-backed Python module (cached)
#' @keywords internal
provider_module <- function() {
  if (is.null(.provider_env$mod)) {
    # EcoLogits declares pydantic >= 1.9 but imports names that only exist in 2.
    reticulate::py_require(c("ecologits", "pydantic>=2"))
    path <- system.file("python", package = "tidycarbon")
    if (!nzchar(path)) rlang::abort("Cannot find tidycarbon's inst/python directory.")
    .provider_env$mod <- reticulate::import_from_path("tidycarbon_provider", path = path)
  }
  .provider_env$mod
}

# Python list (NULL for None) -> atomic R vector of `type`.
py_col <- function(x, type) {
  na <- type[NA_integer_]
  vapply(as.list(x), function(v) {
    if (is.null(v) || length(v) == 0) na else as.vector(v, typeof(na))
  }, na, USE.NAMES = FALSE)
}

#' Build a calls table: one row per billed LLM request
#'
#' The standard input to [carbon_provider()] and [carbon_tokens()]. Use it
#' directly for clients other than ellmer (rollama, httr2, ...), passing the
#' `usage` counts the API returned.
#'
#' @param model Model name as the provider's API names it, e.g.
#'   `"claude-sonnet-4-5"` or `"gpt-4o"`. It is passed to EcoLogits unchanged.
#' @param output_tokens Output tokens billed for the request.
#' @param provider Provider that served the request: `"anthropic"`, `"openai"`,
#'   `"mistralai"`, `"google_genai"`, `"cohere"` or `"huggingface_hub"`, or the
#'   name ellmer gives it (`"Google/Gemini"`). With `"OpenRouter"`, the
#'   provider is read from the model id instead (`"openai/gpt-4o"`).
#' @param input_tokens,cache_read,cache_write Uncached input, cache-read and
#'   cache-write input tokens. Reported by [carbon_tokens()]; not used by the
#'   EcoLogits estimate.
#' @param latency_s Request wall-clock latency in seconds, or `NA` if unknown.
#' @param ts Request time (POSIXct), or `NA`.
#' @return A tibble with one row per request.
#' @export
carbon_calls <- function(model,
                         output_tokens,
                         provider = "",
                         input_tokens = 0,
                         cache_read = 0,
                         cache_write = 0,
                         latency_s = NA_real_,
                         ts = as.POSIXct(NA)) {
  tibble::tibble(
    ts            = as.POSIXct(ts),
    provider      = as.character(provider),
    model         = as.character(model),
    input_tokens  = as.numeric(input_tokens),
    cache_read    = as.numeric(cache_read),
    cache_write   = as.numeric(cache_write),
    output_tokens = as.numeric(output_tokens),
    latency_s     = as.numeric(latency_s)
  )
}

#' Calls table from an ellmer chat
#'
#' Reads the token counts ellmer stores on each assistant turn, and the model
#' and provider from `chat$get_provider()`.
#'
#' Latency is the request duration ellmer records on each turn (ellmer >=
#' 0.4.0). Older versions record none, so `latency_s` is used instead. ellmer
#' does not record per-request timestamps, so `ts` is `NA`, and the cache
#' columns are `0` (or `cache_read` holds ellmer's cached-input count where
#' available).
#'
#' @param chat An ellmer `Chat` object.
#' @param since Number of turns (user and assistant) to skip, e.g. the turn
#'   count before the code being tracked ran.
#' @param latency_s Latency upper bound for requests ellmer recorded no
#'   duration for, e.g. the wall time of the tracked block.
#' @return A calls tibble (see [carbon_calls()]).
#' @export
calls_from_ellmer <- function(chat, since = 0, latency_s = NA_real_) {
  rlang::check_installed(c("ellmer", "S7"), "to read token usage from an ellmer chat.")
  turns <- chat$get_turns()
  turns <- turns[seq_along(turns) > since]
  turns <- Filter(function(t) identical(S7::prop(t, "role"), "assistant"), turns)

  p <- chat$get_provider()
  model <- S7::prop(p, "model")
  provider <- tryCatch(S7::prop(p, "name"), error = function(e) "")

  tok <- lapply(turns, function(t) as.numeric(S7::prop(t, "tokens")))
  get <- function(i) vapply(tok, function(x) if (length(x) >= i) x[[i]] else if (i == 3) 0 else NA_real_, numeric(1))
  duration <- vapply(turns, function(t) {
    as.numeric(tryCatch(S7::prop(t, "duration"), error = function(e) NA_real_))
  }, numeric(1))

  carbon_calls(
    model         = rep(model, length(turns)),
    output_tokens = get(2),
    provider      = rep(provider, length(turns)),
    input_tokens  = get(1),
    cache_read    = get(3),
    latency_s     = dplyr::coalesce(duration, rep(as.numeric(latency_s), length(turns))),
    ts            = rep(as.POSIXct(NA), length(turns))
  )
}

#' Calls table from a Claude Code session transcript
#'
#' Reads the billed `usage` of every request in a Claude Code session log
#' (`~/.claude/projects/<slug>/<session-uuid>.jsonl`), deduplicated on message
#' id, including subagent requests. Latency is derived from the transcript and
#' is an upper bound.
#'
#' @param path Path to the `.jsonl` transcript.
#' @param start,end Optional POSIXct (or ISO-8601 string) bounds of the window.
#' @return A calls tibble (see [carbon_calls()]) with an extra `sidechain`
#'   column (`TRUE` for subagent requests).
#' @export
calls_from_transcript <- function(path, start = NULL, end = NULL) {
  iso <- function(x) {
    if (is.null(x)) return(NULL)
    if (inherits(x, "POSIXt")) format(x, "%Y-%m-%dT%H:%M:%OS6Z", tz = "UTC") else as.character(x)
  }
  cols <- provider_module()$read_claude_code(path.expand(path), iso(start), iso(end))
  out <- carbon_calls(
    model         = py_col(cols$model, character()),
    output_tokens = py_col(cols$output_tokens, numeric()),
    provider      = py_col(cols$provider, character()),
    input_tokens  = py_col(cols$input_tokens, numeric()),
    cache_read    = py_col(cols$cache_read, numeric()),
    cache_write   = py_col(cols$cache_write, numeric()),
    latency_s     = py_col(cols$latency_s, numeric()),
    ts            = as.POSIXct(py_col(cols$ts, character()), format = "%Y-%m-%dT%H:%M:%OS", tz = "UTC")
  )
  out$latency_s[is.nan(out$latency_s)] <- NA_real_
  out$sidechain <- py_col(cols$sidechain, logical())
  out
}

#' Token accounting for a calls table
#'
#' @param calls A calls tibble (or the output of [carbon_provider()]).
#' @return A one-row tibble: `calls`, `sent` (input + cache read + cache
#'   write), `received` (output), `total`, `cache_hit_pct` and
#'   `avg_context` (mean tokens sent per call).
#' @export
carbon_tokens <- function(calls) {
  sent_each <- calls$input_tokens + calls$cache_read + calls$cache_write
  sent <- sum(sent_each, na.rm = TRUE)
  received <- sum(calls$output_tokens, na.rm = TRUE)
  cache_read <- sum(calls$cache_read, na.rm = TRUE)
  n <- nrow(calls)
  tibble::tibble(
    calls         = n,
    sent          = sent,
    received      = received,
    total         = sent + received,
    cache_hit_pct = if (sent > 0) 100 * cache_read / sent else NA_real_,
    avg_context   = if (n > 0) mean(sent_each, na.rm = TRUE) else NA_real_
  )
}

#' Estimate provider-side inference impacts with EcoLogits
#'
#' Runs one EcoLogits computation per request - never on token totals, since
#' the model is non-linear - and returns the calls table with the estimate
#' appended. See [provider-impacts] for the caveats.
#'
#' @param calls A calls tibble (see [carbon_calls()]).
#' @param zone Optional electricity-mix zone (e.g. `"FRA"`) charged to every
#'   provider. Default `NULL` charges each provider to its own datacenter
#'   location as EcoLogits records it.
#' @return The calls tibble with `provider` as the EcoLogits provider id and
#'   the columns `modelled`, `error` (the
#'   [EcoLogits error code](https://ecologits.ai/latest/tutorial/warnings_and_errors/)
#'   of an unmodelled request, e.g. `"model-not-registered"`, else `NA`),
#'   `warnings` (its warning codes, comma-separated, else `NA`), `grid_zone`,
#'   and the lower bound, mean and upper bound `energy_kwh_min/mean/max`,
#'   `gwp_kg_min/mean/max`, `water_l_min/mean/max`, `pe_mj_min/mean/max`,
#'   `adpe_kgsb_min/mean/max`. The mean is the midpoint of the range.
#'   Unmodelled rows have `NA` impacts.
#' @export
carbon_provider <- function(calls, zone = NULL) {
  n <- nrow(calls)
  if (n == 0) {
    cols <- list(provider = list(), modelled = list(), error = list(),
                 warnings = list(), grid_zone = list())
    for (i in c("energy", "gwp", "adpe", "pe", "wcf")) {
      cols[[paste0(i, "_min")]] <- list()
      cols[[paste0(i, "_max")]] <- list()
    }
  } else {
    cols <- provider_module()$estimate(
      as.list(dplyr::coalesce(calls$provider, "")),
      as.list(calls$model),
      as.list(as.numeric(calls$output_tokens)),
      as.list(as.numeric(calls$latency_s)),
      zone
    )
  }
  num <- function(name) {
    x <- py_col(cols[[name]], numeric())
    x[is.nan(x)] <- NA_real_
    x
  }
  calls$provider  <- py_col(cols$provider, character())
  calls$modelled  <- py_col(cols$modelled, logical())
  calls$error     <- dplyr::na_if(py_col(cols$error, character()), "")
  calls$warnings  <- dplyr::na_if(py_col(cols$warnings, character()), "")
  calls$grid_zone <- dplyr::na_if(py_col(cols$grid_zone, character()), "")
  # The mean is the midpoint of the range, so it equals both bounds when
  # EcoLogits returns a single value.
  units <- c(energy = "energy_kwh", gwp = "gwp_kg", wcf = "water_l", pe = "pe_mj", adpe = "adpe_kgsb")
  for (i in names(units)) {
    lo <- num(paste0(i, "_min"))
    hi <- num(paste0(i, "_max"))
    calls[[paste0(units[[i]], "_min")]]  <- lo
    calls[[paste0(units[[i]], "_mean")]] <- (lo + hi) / 2
    calls[[paste0(units[[i]], "_max")]]  <- hi
  }
  calls
}

#' Summarise provider-side impacts
#'
#' Sums the per-request estimates separately at the lower bound, the mean and
#' the upper bound (the bounds are deliberately conservative: they assume
#' every request sits at the same end of its range). Unmodelled requests are
#' counted but not summed.
#'
#' @param x Output of [carbon_provider()].
#' @param by `"total"` for one row, or `"model"` for one row per provider and
#'   model.
#' @return A tibble with `calls`, `n_modelled`, `output_tokens`,
#'   `output_tokens_unmodelled`, and summed `*_min` / `*_mean` / `*_max`
#'   impact columns.
#' @export
carbon_provider_summary <- function(x, by = c("total", "model")) {
  by <- match.arg(by)
  impact_cols <- grep("_(min|mean|max)$", names(x), value = TRUE)
  groups <- if (by == "model") c("provider", "model", "error") else character()

  x |>
    dplyr::group_by(dplyr::across(dplyr::all_of(groups))) |>
    dplyr::summarise(
      calls                    = dplyr::n(),
      n_modelled               = sum(.data$modelled),
      # Unmodelled first: once `output_tokens` is summarised it masks the column.
      output_tokens_unmodelled = sum(.data$output_tokens[!.data$modelled], na.rm = TRUE),
      output_tokens            = sum(.data$output_tokens[.data$modelled], na.rm = TRUE),
      dplyr::across(dplyr::all_of(impact_cols),
                    ~ if (any(.data$modelled)) sum(.x[.data$modelled]) else NA_real_),
      .groups = "drop"
    )
}

chat_turn_count <- function(chat) {
  length(chat$get_turns())
}

#' Initialize a remote tracker
#'
#' The provider-side counterpart of [carbon_init()]. Where a CodeCarbon tracker
#' measures the electricity this machine draws, a remote tracker watches one or
#' more ellmer chats and estimates the provider-side impact of the requests
#' they make (see [provider-impacts]). It goes wherever a CodeCarbon tracker
#' goes: [carbon_track()], [carbon_track_all()], [carbon_run()],
#' [carbon_step()], [tracker_start()] / [tracker_stop()].
#'
#' Only requests made through the watched chat objects are seen; a chat that is
#' cloned or created inside the tracked code is not.
#'
#' @param chat An ellmer `Chat`, or a list of them.
#' @param project_name Name of the project.
#' @param engine Method used to estimate the impact of each request. Only
#'   `"ecologits"` ([EcoLogits](https://ecologits.ai)) is available for now.
#' @param zone Optional electricity-mix zone, as in [carbon_provider()].
#' @return A `remote_tracker`. Its windows return a 1-row tibble with
#'   `timestamp`, `duration`, the lower bound, mean and upper bound
#'   `emissions_total_min/mean/max` (kgCO2eq), `energy_consumed_min/mean/max`
#'   (kWh), `water_consumed_min/mean/max` (L), `n_calls`, `n_modelled`, `output_tokens`,
#'   `engine`, `engine_version` and `calls`, a list-column holding the
#'   per-request table from the engine (see [carbon_provider()]).
#' @export
carbon_init_remote <- function(chat,
                               project_name = "rtest",
                               engine = c("ecologits"),
                               zone = NULL) {
  engine <- match.arg(engine)
  rlang::check_installed(c("ellmer", "S7"), "to track an ellmer chat.")
  chats <- if (inherits(chat, "Chat")) list(chat) else as.list(chat)
  if (length(chats) == 0 || !all(vapply(chats, inherits, logical(1), "Chat"))) {
    rlang::abort("`chat` must be an ellmer Chat or a list of them.")
  }
  # Fail here rather than after the tracked code has run.
  version <- switch(engine, ecologits = provider_module()$VERSION)

  self <- new.env(parent = emptyenv())
  self$project_name <- project_name
  self$chats <- chats
  self$engine <- engine
  self$engine_version <- version
  self$zone <- zone
  self$marks <- list()
  # Same interface as a CodeCarbon tracker: a run window and a task window.
  self$start      <- function() remote_mark(self, "run")
  self$stop       <- function() remote_measure(self, "run")
  self$start_task <- function() remote_mark(self, "task")
  self$stop_task  <- function() remote_measure(self, "task")
  class(self) <- "remote_tracker"
  self
}

is_remote <- function(tracker) inherits(tracker, "remote_tracker")

# Per-request estimate of a calls table by the tracker's engine.
remote_estimate <- function(tracker, calls) {
  switch(tracker$engine,
    ecologits = carbon_provider(calls, zone = tracker$zone)
  )
}

remote_mark <- function(tracker, window) {
  tracker$marks[[window]] <- list(
    turns = vapply(tracker$chats, chat_turn_count, integer(1)),
    t0    = Sys.time()
  )
  invisible(tracker)
}

remote_measure <- function(tracker, window) {
  mark <- tracker$marks[[window]]
  if (is.null(mark)) rlang::abort("Remote tracker was not started.")
  tracker$marks[[window]] <- NULL
  duration <- as.numeric(difftime(Sys.time(), mark$t0, units = "secs"))

  calls <- purrr::map2(tracker$chats, mark$turns, function(chat, since) {
    calls_from_ellmer(chat, since = since, latency_s = duration)
  })
  calls <- remote_estimate(tracker, dplyr::bind_rows(calls))
  s <- carbon_provider_summary(calls)
  # No requests is a true zero; requests that could not be modelled stay NA.
  bound <- function(x) if (nrow(calls) == 0) 0 else x

  tibble::tibble(
    timestamp           = as.character(Sys.time()),
    duration            = duration,
    emissions_total_min = bound(s$gwp_kg_min),
    emissions_total_mean = bound(s$gwp_kg_mean),
    emissions_total_max = bound(s$gwp_kg_max),
    energy_consumed_min = bound(s$energy_kwh_min),
    energy_consumed_mean = bound(s$energy_kwh_mean),
    energy_consumed_max = bound(s$energy_kwh_max),
    water_consumed_min  = bound(s$water_l_min),
    water_consumed_mean = bound(s$water_l_mean),
    water_consumed_max  = bound(s$water_l_max),
    n_calls             = s$calls,
    n_modelled          = s$n_modelled,
    output_tokens       = sum(calls$output_tokens, na.rm = TRUE),
    engine              = tracker$engine,
    engine_version      = tracker$engine_version,
    calls               = list(calls)
  )
}

# A tracker window as a carbon_run() / carbon_step() log row.
remote_log <- function(row, task_id, label) {
  dplyr::bind_cols(
    tibble::tibble(task_id = task_id, label = label),
    tibble::add_column(row, wall_time_sec = row$duration, .after = "timestamp"),
    tibble::tibble(output_source = row$engine)
  )
}
