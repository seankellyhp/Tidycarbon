
# install.packages("keras3")
# keras3::install_keras(backend = "tensorflow")

library(keras3)

# Prepare data
mnist <- dataset_mnist()
x_train <- mnist$train$x
y_train <- mnist$train$y
x_test <- mnist$test$x
y_test <- mnist$test$y

# reshape
x_train <- array_reshape(x_train, c(nrow(x_train), 784))
x_test <- array_reshape(x_test, c(nrow(x_test), 784))

# rescale
x_train <- x_train / 255
x_test <- x_test / 255

y_train <- to_categorical(y_train, 10)
y_test <- to_categorical(y_test, 10)

# Define model
model <- keras_model_sequential(input_shape = c(784))
model |>
  layer_dense(units = 256, activation = 'relu') |>
  layer_dropout(rate = 0.4) |>
  layer_dense(units = 128, activation = 'relu') |>
  layer_dropout(rate = 0.3) |>
  layer_dense(units = 10, activation = 'softmax')

# summary(model)

# Compile Model
model |> compile(
  loss = 'categorical_crossentropy',
  optimizer = optimizer_rmsprop(),
  metrics = c('accuracy')
)

# Ready the tracker
library(tidycarbon)
tracker <- carbon_init(project_name = "MNIST Training")
reticulate::py_install("codecarbon") # Conflict with other venv made by keras3. Add to source, if fail because already within a venv, install manually

# Start Tracking
tracker_start(tracker)

# Train Model
history <- model |> fit(
  x_train, y_train,
  epochs = 30, batch_size = 128,
  validation_split = 0.2
)

# End Tracking
tracker_stop(tracker)

# Predict 
model |> evaluate(x_test, y_test)

# probs <- model |> predict(x_test)
# max.col(probs) - 1L