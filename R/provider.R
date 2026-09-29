#' Provider-side inference impacts and token accounting
#'
#' CodeCarbon measures the electricity *this machine* draws. When R code calls a
#' hosted LLM, the inference runs in the provider's datacenter, which CodeCarbon
#' cannot see. These functions estimate that provider-side impact with
#' [EcoLogits](https://ecologits.ai) from the billed token usage of each request.
#'
#' Everything starts from a *calls* table, one row per billed request (see
#' [carbon_calls()]), built from an ellmer chat ([calls_from_ellmer()]), a
#' Claude Code session transcript ([calls_from_transcript()]) or by hand.
#'
#' Caveats, carried into every result:
#' * **Only output tokens and latency enter the EcoLogits model.** Input and
#'   cache tokens contribute nothing, so the estimate prices output
#'   generation, not "the impact of the conversation".
#' * **Figures are ranges** (`*_min` / `*_max`) whenever the provider does not
#'   publish its model's architecture. A published one gives `min == max`.
#' * **Latency can only lower the estimate.** An unknown latency (`NA`) leaves
#'   the modelled generation time uncapped.
#' * **Models newer than the EcoLogits release** are computed as the nearest
#'   registered model of the same family; the `resolution` column says so.
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
    reticulate::py_require("ecologits")
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
#' @param model Model name as the client recorded it, e.g. `"claude-sonnet-4-5"`,
#'   `"openai/gpt-4o"`, `"us.anthropic.claude-opus-4-1-20250805-v1:0"`.
#' @param output_tokens Output tokens billed for the request.
#' @param provider Optional provider hint (`"anthropic"`, `"openai"`, ...),
#'   used when the model string does not name one.
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
#' ellmer does not record per-request timestamps or latency, and older
#' versions do not record cached input, so `ts` and `latency_s` are `NA`
#' unless `latency_s` is supplied, and the cache columns are `0` (or
#' `cache_read` holds ellmer's cached-input count where available).
#'
#' @param chat An ellmer `Chat` object.
#' @param since Number of turns (user and assistant) to skip, e.g. the turn
#'   count before the code being tracked ran.
#' @param latency_s Optional latency upper bound applied to every request,
#'   e.g. the wall time of the tracked block.
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

  carbon_calls(
    model         = rep(model, length(turns)),
    output_tokens = get(2),
    provider      = rep(provider, length(turns)),
    input_tokens  = get(1),
    cache_read    = get(3),
    latency_s     = rep(latency_s, length(turns)),
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
#' @return The calls tibble with `provider` normalised and the columns
#'   `resolved_model`, `resolution`, `modelled`, `grid_zone`, and the lower and
#'   upper bounds `energy_kwh_min/max`, `gwp_kg_min/max`, `water_l_min/max`,
#'   `pe_mj_min/max`, `adpe_kgsb_min/max`. Unmodelled rows have `NA` impacts.
#' @export
carbon_provider <- function(calls, zone = NULL) {
  n <- nrow(calls)
  if (n == 0) {
    cols <- list(provider = list(), resolved_model = list(), resolution = list(),
                 modelled = list(), grid_zone = list())
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
  calls$provider       <- py_col(cols$provider, character())
  calls$resolved_model <- dplyr::na_if(py_col(cols$resolved_model, character()), "")
  calls$resolution     <- py_col(cols$resolution, character())
  calls$modelled       <- py_col(cols$modelled, logical())
  calls$grid_zone      <- dplyr::na_if(py_col(cols$grid_zone, character()), "")
  calls$energy_kwh_min <- num("energy_min")
  calls$energy_kwh_max <- num("energy_max")
  calls$gwp_kg_min     <- num("gwp_min")
  calls$gwp_kg_max     <- num("gwp_max")
  calls$water_l_min    <- num("wcf_min")
  calls$water_l_max    <- num("wcf_max")
  calls$pe_mj_min      <- num("pe_min")
  calls$pe_mj_max      <- num("pe_max")
  calls$adpe_kgsb_min  <- num("adpe_min")
  calls$adpe_kgsb_max  <- num("adpe_max")
  calls
}

#' Summarise provider-side impacts
#'
#' Sums the per-request estimates separately at the lower and upper bound
#' (deliberately conservative: it assumes every request sits at the same end
#' of its range). Unmodelled requests are counted but not summed.
#'
#' @param x Output of [carbon_provider()].
#' @param by `"total"` for one row, or `"model"` for one row per model and
#'   how it was resolved.
#' @return A tibble with `calls`, `n_modelled`, `output_tokens`,
#'   `output_tokens_unmodelled`, and summed `*_min` / `*_max` impact columns.
#' @export
carbon_provider_summary <- function(x, by = c("total", "model")) {
  by <- match.arg(by)
  impact_cols <- grep("_(min|max)$", names(x), value = TRUE)
  groups <- if (by == "model") c("provider", "model", "resolved_model", "resolution") else character()

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

# Provider estimate for the ellmer turns added since `since`, for the tracker
# hooks. Never lets a provider failure break the user's tracked code.
provider_for_chat <- function(chat, since, wall_time_sec) {
  tryCatch(
    carbon_provider(calls_from_ellmer(chat, since = since, latency_s = wall_time_sec)),
    error = function(e) {
      rlang::warn(paste("Provider impacts not estimated:", conditionMessage(e)))
      NULL
    }
  )
}

chat_turn_count <- function(chat) {
  if (is.null(chat)) return(NA_integer_)
  length(chat$get_turns())
}
