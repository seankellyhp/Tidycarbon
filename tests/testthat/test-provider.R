skip_if_no_ecologits <- function() {
  skip_on_cran()
  ok <- tryCatch({
    provider_module()
    TRUE
  }, error = function(e) FALSE)
  if (!ok) skip("ecologits not available through reticulate")
}

test_that("the provider comes from the client, or from an OpenRouter model id", {
  skip_if_no_ecologits()
  split <- function(p, m) unlist(provider_module()$split_model(p, m))

  expect_equal(split("OpenAI", "gpt-4o"), c("openai", "gpt-4o"))
  expect_equal(split("Google/Gemini", "gemini-2.5-flash"), c("google_genai", "gemini-2.5-flash"))
  expect_equal(split("OpenRouter", "openai/gpt-4o"), c("openai", "gpt-4o"))
  expect_equal(split("OpenRouter", "meta-llama/llama-3.1-8b-instruct"),
               c("", "meta-llama/llama-3.1-8b-instruct"))
  # Only OpenRouter's ids are split.
  expect_equal(split("", "anthropic/claude-sonnet-4-5"), c("", "anthropic/claude-sonnet-4-5"))
  # A known provider's model name is never rewritten.
  expect_equal(split("HuggingFace", "meta-llama/Meta-Llama-3.1-8B-Instruct"),
               c("huggingface_hub", "meta-llama/Meta-Llama-3.1-8B-Instruct"))
  expect_equal(split("", "claude-sonnet-4-5"), c("", "claude-sonnet-4-5"))
})

test_that("carbon_provider estimates per request and reports EcoLogits' errors", {
  skip_if_no_ecologits()
  calls <- carbon_calls(
    model         = c("claude-sonnet-4-5", "claude-opus-99", "claude-sonnet-4-5", "claude-sonnet-4-5"),
    output_tokens = c(500, 500, NA, 500),
    provider      = c("anthropic", "anthropic", "anthropic", ""),
    latency_s     = c(30, NA, NA, NA)
  )
  x <- carbon_provider(calls)

  expect_equal(nrow(x), 4)
  expect_equal(x$modelled, c(TRUE, FALSE, FALSE, FALSE))
  expect_equal(x$error, c(NA, "model-not-registered", "missing-output-tokens", "model-not-registered"))
  expect_match(x$warnings[1], "model-arch-not-released")
  expect_true(all(is.na(x$energy_kwh_min[2:4])))
  expect_true(x$energy_kwh_min[1] > 0)
  expect_true(x$energy_kwh_max[1] >= x$energy_kwh_min[1])
  expect_equal(x$energy_kwh_mean, (x$energy_kwh_min + x$energy_kwh_max) / 2)
  expect_equal(x$grid_zone, c("USA", NA, NA, NA))
})

test_that("carbon_provider returns what EcoLogits returns", {
  skip_if_no_ecologits()
  x <- carbon_provider(carbon_calls("gpt-4o", 250, provider = "OpenAI", latency_s = 2))
  ref <- reticulate::import("ecologits.tracers.utils")$llm_impacts(
    provider = "openai", model_name = "gpt-4o",
    output_token_count = 250L, request_latency = 2
  )
  expect_equal(x$provider, "openai")
  expect_equal(x$energy_kwh_min, ref$energy$value$min)
  expect_equal(x$energy_kwh_max, ref$energy$value$max)
  expect_equal(x$gwp_kg_max, ref$gwp$value$max)
  expect_equal(x$water_l_min, ref$wcf$value$min)
})

test_that("an unregistered zone is an EcoLogits error, not a silent NA", {
  skip_if_no_ecologits()
  calls <- carbon_calls("claude-sonnet-4-5", 100, provider = "anthropic")
  expect_equal(carbon_provider(calls, zone = "FR")$error, "zone-not-registered")
  expect_equal(carbon_provider(calls, zone = "FRA")$grid_zone, "FRA")
})

test_that("carbon_provider_summary sums bound-wise and reports the unmodelled", {
  skip_if_no_ecologits()
  x <- carbon_provider(carbon_calls(
    model = c("claude-sonnet-4-5", "claude-sonnet-4-5", "not-a-model"),
    output_tokens = c(100, 300, 50),
    provider = "anthropic"
  ))
  s <- carbon_provider_summary(x)

  expect_equal(nrow(s), 1)
  expect_equal(s$calls, 3)
  expect_equal(s$n_modelled, 2)
  expect_equal(s$output_tokens, 400)
  expect_equal(s$output_tokens_unmodelled, 50)
  expect_equal(s$energy_kwh_min, sum(x$energy_kwh_min[1:2]))
  expect_equal(s$gwp_kg_max, sum(x$gwp_kg_max[1:2]))
  expect_equal(s$gwp_kg_mean, (s$gwp_kg_min + s$gwp_kg_max) / 2)

  m <- carbon_provider_summary(x, by = "model")
  expect_equal(nrow(m), 2)
  expect_true(is.na(m$energy_kwh_min[m$model == "not-a-model"]))
})

test_that("carbon_provider handles an empty calls table", {
  x <- carbon_provider(carbon_calls(character(), numeric()))
  expect_equal(nrow(x), 0)
  expect_true("energy_kwh_min" %in% names(x))
})

test_that("carbon_tokens reports sent, received and cache hit rate", {
  t <- carbon_tokens(carbon_calls(
    model = c("m", "m"), output_tokens = c(10, 20),
    input_tokens = c(100, 0), cache_read = c(0, 300), cache_write = c(100, 0)
  ))
  expect_equal(t$calls, 2)
  expect_equal(t$sent, 500)
  expect_equal(t$received, 30)
  expect_equal(t$total, 530)
  expect_equal(t$cache_hit_pct, 60)
  expect_equal(t$avg_context, 250)
})

test_that("calls_from_ellmer reads assistant turns after `since`", {
  skip_if_not_installed("ellmer")
  chat <- ellmer::chat_anthropic(model = "claude-sonnet-4-5", api_key = "not-used")
  chat$set_turns(list(
    ellmer::Turn("user", list(ellmer::ContentText("a"))),
    ellmer::Turn("assistant", list(ellmer::ContentText("b")), tokens = c(10, 5)),
    ellmer::Turn("user", list(ellmer::ContentText("c"))),
    ellmer::Turn("assistant", list(ellmer::ContentText("d")), tokens = c(20, 7))
  ))

  all <- calls_from_ellmer(chat)
  expect_equal(nrow(all), 2)
  expect_equal(all$output_tokens, c(5, 7))
  expect_equal(all$input_tokens, c(10, 20))
  expect_equal(all$model, rep("claude-sonnet-4-5", 2))
  expect_equal(all$provider, rep("Anthropic", 2))

  new <- calls_from_ellmer(chat, since = 2, latency_s = 3)
  expect_equal(nrow(new), 1)
  expect_equal(new$output_tokens, 7)
  expect_equal(new$latency_s, 3)
})

test_that("calls_from_transcript dedupes on message id and derives latency", {
  skip_if_no_ecologits()
  path <- tempfile(fileext = ".jsonl")
  usage <- '{"input_tokens":3,"cache_read_input_tokens":100,"cache_creation_input_tokens":20,"output_tokens":50}'
  writeLines(c(
    '{"uuid":"u1","timestamp":"2026-01-01T10:00:00Z","message":{"role":"user","content":"hi"}}',
    paste0('{"uuid":"a1","parentUuid":"u1","timestamp":"2026-01-01T10:00:04Z","message":{"id":"m1","model":"claude-sonnet-4-5","usage":', usage, '}}'),
    paste0('{"uuid":"a2","parentUuid":"a1","timestamp":"2026-01-01T10:00:06Z","message":{"id":"m1","model":"claude-sonnet-4-5","usage":', usage, '}}'),
    paste0('{"uuid":"a3","parentUuid":"a2","isSidechain":true,"timestamp":"2026-01-01T11:00:00Z","message":{"id":"m2","model":"claude-opus-5","usage":', usage, '}}')
  ), path)

  x <- calls_from_transcript(path)
  expect_equal(nrow(x), 2)
  expect_equal(x$output_tokens, c(50, 50))
  expect_equal(x$latency_s[1], 6)
  expect_equal(x$sidechain, c(FALSE, TRUE))
  expect_equal(carbon_tokens(x)$sent, 246)

  windowed <- calls_from_transcript(path, end = as.POSIXct("2026-01-01 10:30:00", tz = "UTC"))
  expect_equal(nrow(windowed), 1)
})

test_that("calls_from_transcript measures latency from the triggering message", {
  skip_if_no_ecologits()
  path <- tempfile(fileext = ".jsonl")
  usage <- '{"input_tokens":3,"output_tokens":50}'
  writeLines(c(
    '{"uuid":"u1","timestamp":"2026-01-01T10:00:00Z","message":{"role":"user","content":"hi"}}',
    '{"uuid":"x1","parentUuid":"u1","type":"attachment","timestamp":"2026-01-01T10:00:00Z"}',
    '{"uuid":"x2","parentUuid":"x1","type":"attachment","timestamp":"2026-01-01T10:00:03Z"}',
    paste0('{"uuid":"a1","parentUuid":"x2","timestamp":"2026-01-01T10:00:03Z","message":{"id":"m1","model":"claude-sonnet-4-5","usage":', usage, '}}'),
    paste0('{"uuid":"a2","parentUuid":"missing","timestamp":"2026-01-01T10:00:09Z","message":{"id":"m2","model":"claude-sonnet-4-5","usage":', usage, '}}')
  ), path)

  x <- calls_from_transcript(path)
  expect_equal(x$latency_s[1], 3)
  expect_identical(x$latency_s[2], NA_real_)
})

# A chat whose `ask()` appends a user/assistant exchange without calling an API.
fake_chat <- function(model = "claude-sonnet-4-5") {
  chat <- ellmer::chat_anthropic(model = model, api_key = "not-used")
  ask <- function(output_tokens = 100) {
    chat$set_turns(c(chat$get_turns(), list(
      ellmer::Turn("user", list(ellmer::ContentText("q"))),
      ellmer::Turn("assistant", list(ellmer::ContentText("a")), tokens = c(10, output_tokens))
    )))
    "a"
  }
  list(chat = chat, ask = ask)
}

test_that("a remote tracker drives carbon_track like a CodeCarbon one", {
  skip_if_not_installed("ellmer")
  skip_if_no_ecologits()
  f <- fake_chat()
  f$ask(999)                                   # before the window: not counted
  dir <- file.path(tempdir(), "remote-track")
  unlink(dir, recursive = TRUE)
  tracker <- carbon_init_remote(f$chat, project_name = "p", output_dir = dir)

  res <- carbon_track(function(n) { f$ask(n); f$ask(n) }, n = 200, tracker = tracker)
  expect_equal(nrow(res), 1)
  expect_equal(res$project_name, "p")
  expect_equal(res$engine, "ecologits")
  expect_equal(res$result[[1]], "a")
  expect_equal(res$n_calls, 2)
  expect_equal(res$n_modelled, 2)
  expect_equal(res$output_tokens, 400)
  expect_true(res$energy_consumed_min > 0)
  expect_true(res$emissions_total_max >= res$emissions_total_min)
  expect_equal(res$energy_consumed_mean, (res$energy_consumed_min + res$energy_consumed_max) / 2)
  expect_equal(nrow(res$calls[[1]]), 2)
  expect_equal(res$energy_consumed_max, sum(res$calls[[1]]$energy_kwh_max))

  all <- carbon_track_all(list(
    list(fun = function() f$ask(50), args = list()),
    list(fun = function() NULL, args = list())
  ), tracker)
  expect_equal(all$n_calls, c(1, 0))
  expect_equal(all$energy_consumed_max[2], 0)

  # Every window landed in the tracker's own artifact, without `calls`.
  art <- carbon_read(dir, "emissions_remote.csv")
  expect_equal(art$n_calls, c(2, 1, 0))
  expect_equal(art$energy_consumed_max[1], res$energy_consumed_max)
  expect_false("calls" %in% names(art))
})

test_that("a remote tracker drives carbon_run, carbon_step and global tracking", {
  skip_if_not_installed("ellmer")
  skip_if_no_ecologits()
  f <- fake_chat()
  dir <- file.path(tempdir(), "remote-run")
  unlink(dir, recursive = TRUE)
  tracker <- carbon_init_remote(f$chat, output_dir = dir, output_file = "llm.csv")

  run <- carbon_run({ f$ask(100); 42 }, tracker = tracker, label = "r")
  expect_equal(run$result, 42)
  expect_equal(run$log$label, "r")
  expect_equal(run$log$n_calls, 1)
  expect_equal(run$log$output_source, "ecologits")

  step <- function(x, n) { f$ask(n); x + 1 }
  out <- 1 |>
    carbon_step(step, n = 100, tracker = tracker, label = "s1") |>
    carbon_step(step, n = 300, tracker = tracker, label = "s2")
  log <- carbon_collect(out)
  expect_equal(as.numeric(out), 3)
  expect_equal(log$label, c("s1", "s2"))
  expect_equal(log$output_tokens, c(100, 300))
  expect_true(log$energy_consumed_max[2] > log$energy_consumed_max[1])

  tracker_start(tracker)
  f$ask(100); f$ask(100)
  total <- tracker_stop(tracker)
  expect_equal(total$n_calls, 2)
  expect_error(tracker_stop(tracker), "not started")
  expect_equal(carbon_read(dir, "llm.csv")$label, c("r", "s1", "s2", "session"))

  quiet <- carbon_init_remote(f$chat, output_dir = NULL)
  carbon_run(f$ask(100), tracker = quiet)
  expect_equal(nrow(carbon_read(dir, "llm.csv")), 4)
})

test_that("carbon_init_remote rejects anything that is not a chat", {
  skip_if_not_installed("ellmer")
  expect_error(carbon_init_remote("claude"), "ellmer Chat")
  expect_error(carbon_init_remote(NULL, engine = "other"), "should be")
})
