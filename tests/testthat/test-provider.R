skip_if_no_ecologits <- function() {
  skip_on_cran()
  ok <- tryCatch({
    provider_module()
    TRUE
  }, error = function(e) FALSE)
  if (!ok) skip("ecologits not available through reticulate")
}

test_that("split_model reads every client spelling", {
  skip_if_no_ecologits()
  split <- function(x) unlist(provider_module()$split_model(x))

  expect_equal(split("claude-opus-5"), c("anthropic", "claude-opus-5"))
  expect_equal(split("anthropic/claude-sonnet-4-5"), c("anthropic", "claude-sonnet-4-5"))
  expect_equal(split("openrouter/anthropic/claude-sonnet-4-5"), c("anthropic", "claude-sonnet-4-5"))
  expect_equal(split("us.anthropic.claude-opus-4-1-20250805-v1:0"),
               c("anthropic", "claude-opus-4-1-20250805"))
  expect_equal(split("gpt-3.5-turbo"), c("", "gpt-3.5-turbo"))
})

test_that("provider hint fills in a bare model name", {
  skip_if_no_ecologits()
  norm <- function(h, m) unlist(provider_module()$normalize(h, m))
  expect_equal(norm("OpenAI", "gpt-4o"), c("openai", "gpt-4o"))
  expect_equal(norm("Google/Gemini", "gemini-2.0-flash"), c("google_genai", "gemini-2.0-flash"))
  expect_equal(norm("OpenAI", "anthropic/claude-sonnet-4-5"), c("anthropic", "claude-sonnet-4-5"))
})

test_that("carbon_provider estimates per request and names each resolution", {
  skip_if_no_ecologits()
  calls <- carbon_calls(
    model         = c("claude-sonnet-4-5", "claude-opus-99", "not-a-model", "claude-sonnet-4-5"),
    output_tokens = c(500, 500, 500, NA),
    latency_s     = c(NA, 30, NA, NA)
  )
  x <- carbon_provider(calls)

  expect_equal(nrow(x), 4)
  expect_equal(x$modelled, c(TRUE, TRUE, FALSE, FALSE))
  expect_equal(x$resolution[1], "exact")
  expect_match(x$resolution[2], "^proxy: nearest registered opus")
  expect_equal(x$resolution[4], "no output token count")
  expect_true(all(is.na(x$energy_kwh_min[3:4])))
  expect_true(all(x$energy_kwh_min[1:2] > 0))
  expect_true(all(x$energy_kwh_max[1:2] >= x$energy_kwh_min[1:2]))
  expect_equal(x$grid_zone[1:2], rep(x$grid_zone[1], 2))
})

test_that("carbon_provider_summary sums bound-wise and reports the unmodelled", {
  skip_if_no_ecologits()
  x <- carbon_provider(carbon_calls(
    model = c("claude-sonnet-4-5", "claude-sonnet-4-5", "not-a-model"),
    output_tokens = c(100, 300, 50)
  ))
  s <- carbon_provider_summary(x)

  expect_equal(nrow(s), 1)
  expect_equal(s$calls, 3)
  expect_equal(s$n_modelled, 2)
  expect_equal(s$output_tokens, 400)
  expect_equal(s$output_tokens_unmodelled, 50)
  expect_equal(s$energy_kwh_min, sum(x$energy_kwh_min[1:2]))
  expect_equal(s$gwp_kg_max, sum(x$gwp_kg_max[1:2]))

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
