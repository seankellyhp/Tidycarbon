# =========================
# Example usage: topic models energy tracking
# =========================

# Packages for example
library(quanteda)
library(quanteda.corpora)   # data_corpus_guardian (install: quanteda/quanteda.corpora)
library(topicmodels)
library(tidycarbon)

pkgload::load_all(".")

df <- download("data_corpus_guardian")

out_dir <- file.path(tempdir(), "tidycarbon_topicmodels")
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

# carbon_init() registers the tracker as the session default, so carbon_run()
# below needs neither tracker= nor output_dir=.
carbon_init(
  project_name = "topicmodels_guardian",
  measure_power_secs = 1,
  output_dir = out_dir,
  output_file = "emissions.csv",
  offline = TRUE
)

k_topics <- 20

# ---- Whole-pipeline tracking (one window) ----
run <- carbon_run({
  dtm_all <- tokens(df,
                    remove_punct = TRUE, remove_symbols = TRUE,
                    remove_numbers = TRUE, remove_url = TRUE) |>
    tokens_tolower() |>
    tokens_remove(stopwords("en")) |>
    tokens_wordstem() |>
    dfm() |>
    dfm_trim(min_termfreq = 10, min_docfreq = 5) |>
    convert(to = "topicmodels")

  LDA(dtm_all, k = k_topics, method = "Gibbs",
      control = list(seed = 42, iter = 100, burnin = 10))
}, label = "whole topicmodels pipeline")

print(run$log)

# Top terms per topic
terms(run$result, 10)

# ---- Read entire CSV (raw CodeCarbon log) ----
csv_all <- carbon_read(out_dir, "emissions.csv")
print(dplyr::glimpse(csv_all))
