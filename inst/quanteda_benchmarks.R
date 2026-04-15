#remotes::install_github("quanteda/quanteda3")
library("quanteda")
library("quanteda.corpora")

library("ggplot2")
library(tidycarbon)


df <- download("data_corpus_guardian")
# create text corpus
corp <- corpus_reshape(df)

# tokenize corpus
toks <- tokens(corp, remove_punct = FALSE, remove_numbers = FALSE, 
               remove_symbols = FALSE)

# transform tokens object to tokens_xptr object
xtoks <- as.tokens_xptr(toks)

ndoc(toks) # the number of sentences
## [1] 200254
sum(ntoken(toks)) # the total number of tokens
## [1] 5322321

### Tokenizing 

microbenchmark::microbenchmark(
  v3 = quanteda3::tokens(corp, remove_punct = TRUE, remove_numbers = TRUE, 
                         remove_symbols = TRUE),
  v4 = tokens(corp, remove_punct = TRUE, remove_numbers = TRUE, 
              remove_symbols = TRUE),
  times = 5
) |> autoplot(log = FALSE)


tracker <- carbon_init(project_name = "microbench")

tracker_start(tracker)
microbenchmark::microbenchmark(
  v3 = quanteda3::tokens(corp, remove_punct = TRUE, remove_numbers = TRUE, 
                         remove_symbols = TRUE),
  v4 = tokens(corp, remove_punct = TRUE, remove_numbers = TRUE, 
              remove_symbols = TRUE),
  times = 10
) |> autoplot(log = FALSE)
tracker_stop(tracker)
  







