
library(tidycarbon)
library(tidyr)
library(tidytext)
library(dplyr)
library(janeaustenr)
library(quanteda)
library(quanteda.sentiment)

tracker <- carbon_init(project_name = "Sentiment Analysis")

# Define Functions to Compare

# Tidytext Dictionary
tidy_sentiment <- function(data, text_col = "text", docid_col = "docid") {
  
  data %>%
    unnest_tokens(word, !!sym(text_col)) %>%
    inner_join(
      get_sentiments("afinn"),
      by = "word",
      relationship = "many-to-many"
    ) %>%
    group_by(!!sym(docid_col)) %>%
    summarise(sentiment = mean(value, na.rm = TRUE))
}

# Quanteda Dictionary
quanteda_sentiment <- function(data, text_col = "text", docid_col = "docid") {
  
  corp <- corpus(
    data,
    text_field = text_col,
    docid_field = docid_col
  )
  
  textstat_valence(
    corp,
    dictionary = data_dictionary_AFINN
  )
}

# Implement Analyses
books <- austen_books() %>%
  mutate(docid = paste0(book, "_", row_number()))

# Create a list of tasks 
sentiment_tasks <- list(
  list(fun = tidy_sentiment, args = list(data = books)),
  list(fun = quanteda_sentiment, args = list(data = books))
)

# Compare Emissions
results_df <- carbon_track_all(sentiment_tasks, tracker)
results_df[,c("task_id", "duration", "energy_consumed", "emissions_total")]

# Compare Results
tidytext_results <- tibble(results_df$result[[1]])
quanteda_results <- tibble(results_df$result[[2]])




