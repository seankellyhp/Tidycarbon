library("quanteda")
library("quanteda.corpora")
library("ggplot2")
library(tidycarbon)

pkgload::load_all(".")

df <- download("data_corpus_guardian")
corp <- corpus_reshape(df)

# Compare quanteda v3 vs v4 tokenization energy use
bench <- carbon_bench(
  v3 = quanteda3::tokens(corp, remove_punct = TRUE,
                                    remove_numbers = TRUE,
                                    remove_symbols = TRUE),
  v4 = tokens(corp, remove_punct = TRUE,
                         remove_numbers = TRUE,
                         remove_symbols = TRUE),
  times = 2,
  project_name = "quanteda_bench_carbon"
) 

autoplot(bench, metric = "duration") +
  scale_y_continuous(labels = scales::label_number(accuracy = 1e-10))

autoplot(bench, metric = "emissions_total") +
  scale_y_continuous(labels = scales::label_number(accuracy = 1e-10))

autoplot(bench, metric = "energy_consumed") +
  scale_y_continuous(labels = scales::label_number(accuracy = 1e-10))

# generate n-grams
carbon_bench(
  v3 = quanteda3::tokens_ngrams(toks),
  v4 = as.tokens_xptr(xtoks) |> 
    tokens_ngrams(),
  times = 3
) |> autoplot(log = FALSE, metric = "emissions_total")


# lookup dictionary keywords
carbon_bench(
  v3 = quanteda3::tokens_lookup(toks, dictionary =  data_dictionary_LSD2015),
  v4 = as.tokens_xptr(xtoks) |> 
    tokens_lookup(dictionary = data_dictionary_LSD2015),
  times = 10
) |> autoplot(log = FALSE, metric = "emissions_total")
