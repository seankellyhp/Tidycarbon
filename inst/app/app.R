# app.R

library(shiny)
library(bslib)
library(dplyr)
library(reticulate) # Required for the custom function

# --- Data Gathering Functions (Outside of Server/UI for efficiency) ---

# Reworked function to get core system info (from previous response)
get_system_info <- function() {
  sys_info_vec <- Sys.info()
  sys_info_df <- data.frame(
    Key = names(sys_info_vec),
    Value = as.character(sys_info_vec),
    stringsAsFactors = FALSE
  )

  r_version_df <- data.frame(
    Key = names(R.version),
    Value = as.character(R.version),
    stringsAsFactors = FALSE
  )
  r_version_df <- r_version_df %>%
    filter(!Key %in% c("os", "system"))

  sys_info_df <- bind_rows(
    data.frame(Key = "--- OS / System Info ---", Value = "", stringsAsFactors = FALSE),
    sys_info_df,
    data.frame(Key = "--- R Version Info ---", Value = "", stringsAsFactors = FALSE),
    r_version_df
  )

  return(sys_info_df)
}

# Function to get full session info text
get_session_info_text <- function() {
  capture.output(sessionInfo())
}

# 📢 YOUR CUSTOM FUNCTION IS ADDED HERE
get_static_machine_info <- function(project_name = "Static_Machine_Info") {
  # 1. Setup and Checks
  if (!requireNamespace("reticulate", quietly = TRUE)) {
    # If reticulate isn't installed, return a placeholder data frame
    return(data.frame(
      Key = "Error",
      Value = "The 'reticulate' package is required but not installed."
    ))
  }

  # Ensure codecarbon is available
  tryCatch({
    py_require("codecarbon")
    carbon <- import("codecarbon")
  }, error = function(e) {
    return(data.frame(
      Key = "Error",
      Value = paste("Could not import 'codecarbon' Python module. Is it installed? Details:", e$message)
    ))
  })

  # Check if codecarbon was successfully imported
  if (!exists("carbon")) {
    return(data.frame(Key = "Error", Value = "Python 'codecarbon' module failed to load."))
  }

  # 2. Setup the Emissions Tracker
  tracker <- carbon$EmissionsTracker(
    project_name = project_name,
    tracking_mode = "machine",
    measure_power_secs = 1,
    output_file = paste0(project_name, ".csv")
  )

  # 3. Start, Execute Minimal Code, and Stop
  message(paste("Starting minimal tracker run to collect data for project:", project_name))
  tracker$start()
  Sys.sleep(0.00001)
  tracker$stop()
  message("Tracker stopped. Retrieving machine configuration details.")

  # 4. Read the generated data file
  csv_file <- paste0(project_name, ".csv")

  if (file.exists(csv_file)) {
    data <- read.csv(csv_file)
    last_row <- tail(data, 1)
    file.remove(csv_file) # Clean up the temporary file

    # 5. Select and format the static information columns
    static_cols <- c(
      "timestamp", "project_name", "run_id", "country_name", "country_iso_code",
      "region", "on_public_cloud", "cloud_provider", "cloud_region",
      "cpu_model", "cpu_power_metric", "gpu_details", "gpu_power_metric",
      "ram_total_size", "ram_power_metric"
    )

    machine_info_raw <- last_row[, names(last_row) %in% static_cols]

    # Convert from a single-row data frame to a Key-Value pair data frame
    machine_info_df <- data.frame(
      Key = names(machine_info_raw),
      Value = as.character(t(machine_info_raw)),
      stringsAsFactors = FALSE
    )

    # Simple formatting/cleaning
    machine_info_df$Key <- gsub("_", " ", machine_info_df$Key)
    machine_info_df$Key <- tools::toTitleCase(machine_info_df$Key)

    return(machine_info_df)
  } else {
    warning("Emissions data file not found. Check project_name and directory.")
    return(data.frame(Key = "Status", Value = "Machine info not collected."))
  }
}


# --- Define UI (User Interface) ---

ui <- page_sidebar(
  theme = bs_theme(bootswatch = "cerulean"),
  title = "Enhanced System Information Dashboard (bslib + codecarbon)",

  sidebar = sidebar(
    title = "About This App",
    p("This app combines base R system info with detailed machine configuration gathered using the Python **codecarbon** library via **reticulate**."),
    hr(),
    h5("Last updated:"),
    textOutput("current_time")
  ),

  # Main Content Area: Use two columns for the static R/OS info and the CodeCarbon info
  layout_columns(
    col_widths = c(6, 6), # Set the column widths to 50/50

    # Column 1: Core System Information (from base R)
    card(
      card_header(h4(icon("desktop"), "Core R & OS Info")),
      tableOutput("sys_info_table")
    ),

    # Column 2: CodeCarbon Machine Configuration (from your custom function)
    card(
      card_header(h4(icon("microchip"), "CodeCarbon Machine Configuration")),
      tableOutput("codecarbon_info_table")
    )
  ),

  # New Row for detailed session info (full width)
  layout_columns(
    col_widths = 12, # Full width card

    # Card 3: Full Session Information (sessionInfo())
    card(
      full_screen = TRUE,
      card_header(h4(icon("code"), "Detailed R Session Info")),
      pre(textOutput("session_info_text"))
    )
  )
)


# --- Define Server Logic ---

server <- function(input, output, session) {

  # Reactive value for the current time in the sidebar
  output$current_time <- renderText({
    invalidateLater(1000, session)
    format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z")
  })

  # --- CodeCarbon Machine Info ---
  # Only run once when the session starts
  machine_info_data <- get_static_machine_info()

  output$codecarbon_info_table <- renderTable({
    machine_info_data
  },
  striped = TRUE,
  hover = TRUE,
  width = "100%",
  align = 'l')

  # --- Core R & OS Info ---
  output$sys_info_table <- renderTable({
    get_system_info()
  },
  striped = TRUE,
  hover = TRUE,
  width = "100%",
  align = 'l')

  # --- Detailed R Session Info ---
  output$session_info_text <- renderText({
    paste(get_session_info_text(), collapse = "\n")
  })
}

# Run the application
shinyApp(ui = ui, server = server, options = list(launch.browser = TRUE))
