# =========================
# Example usage (quanteda stress test)
# =========================

# Packages for example
library(quanteda)
library(quanteda.textmodels)
library(stringi)
library(tidycarbon)


data(data_corpus_irishbudget2010, package = "quanteda.textmodels")

multiplier <- 30
big_corp <- corpus(unname(rep(as.character(data_corpus_irishbudget2010), multiplier)))
docnames(big_corp) <- paste0("doc_", seq_len(ndoc(big_corp)))

# Inflate text (string stress)
txt <- as.character(big_corp)
txt <- stri_trans_tolower(txt)
txt <- paste0(txt, " ", stri_dup(" climate-change ", 25))
txt <- stri_replace_all_regex(txt, "\\b(ireland|irish)\\b", "IRELAND", vectorize_all = FALSE)
txt <- stri_replace_all_regex(txt, "\\s+", " ", vectorize_all = FALSE)
txt_plain <- as.character(txt)
txt_replicated <- rep(txt_plain, multiplier)
big_corp <- corpus(txt_replicated)

out_dir <- file.path(tempdir(), "tidycarbon_test")
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

tracker <- carbon_init_pipe(
  project_name = "package_test",
  measure_power_secs = 1,
  output_dir = out_dir,
  output_file = "emissions.csv",
  offline = TRUE  # will be applied only if your CodeCarbon supports it
)

# ---- Per-step tracking (pipe style) ----
toks <- big_corp |>
  carbon_step(tokens,
              remove_punct=TRUE, remove_symbols=TRUE, remove_numbers=TRUE, remove_url=TRUE,
              tracker=tracker, label="tokens()", output_dir=out_dir) |>
  carbon_step(tokens_tolower, tracker=tracker, label="tokens_tolower()", output_dir=out_dir) |>
  carbon_step(tokens_keep, pattern="^.{3,}$", valuetype="regex",
              tracker=tracker, label="tokens_keep(len>=3)", output_dir=out_dir) |>
  carbon_step(tokens_remove, pattern=stopwords("en"),
              tracker=tracker, label="tokens_remove(stopwords)", output_dir=out_dir) |>
  carbon_step(tokens_wordstem, tracker=tracker, label="tokens_wordstem()", output_dir=out_dir) |>
  carbon_step(tokens_ngrams, n=1:3, tracker=tracker, label="tokens_ngrams(1:3)", output_dir=out_dir)

dfm_big <- toks |>
  carbon_step(dfm, tracker=tracker, label="dfm()", output_dir=out_dir)

logs_step <- carbon_collect(dfm_big)
print(logs_step)

# ---- Whole-pipeline tracking (one window) ----
run <- carbon_run({
  tokens(big_corp, remove_punct=TRUE, remove_symbols=TRUE, remove_numbers=TRUE, remove_url=TRUE) |>
    tokens_tolower() |>
    tokens_keep("^.{3,}$", valuetype="regex") |>
    tokens_remove(stopwords("en")) |>
    tokens_wordstem() |>
    tokens_ngrams(n=1:3) |>
    dfm()
}, tracker = tracker, label = "whole quanteda pipeline", output_dir = out_dir)

print(run$log)

run$log |> View()


# ---- Read entire CSV (raw CodeCarbon log) ----
csv_all <- carbon_read(out_dir, "emissions.csv")
print(dplyr::glimpse(csv_all))
