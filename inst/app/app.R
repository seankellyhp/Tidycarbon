# app.R

library(shiny)
library(bslib)
library(dplyr)
library(reticulate) # Required for the custom function
library(shinycssloaders)

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
  title = h2(style = "color: #F2F2F2;", "Tidycarbon - Dashboard System Consumption (Energy)⚡"),

  sidebar = sidebar(
    title = h4("About This App"),
    p("This app displays comprehensive system information, including R and OS details, and enriches it with machine configuration and carbon emissions metrics collected using the Python codecarbon library (integrated via reticulate).",
      style = "font-size: 20px;"),
    hr(),
    h4("Last updated:"),
    div(
      style = "
        background-color: #353A40;
        color: #F2F2F2;
        padding: 10px 15px;
        border-radius: 8px;
        border: 3px solid #444;
        text-align: center;
        box-shadow: inset 0px 0px 10px #000;
        width: fit-content;
        margin: 10px 0;
      ",
      textOutput("current_time")
    )
  ),

  # Main Content Area with Tabs
  navset_card_underline(
    title = h4(style = "color: #47A4EA;", "Analysis Navigation"),

    # --- TAB 1: Current System Info ---
    nav_panel(
      title = "System Metrics",
      layout_columns(
        col_widths = c(6, 6),
        card(
          bslib::card_header(h4(shiny::icon("desktop"), "Core R & OS Info")),
          shinycssloaders::withSpinner(
            shiny::tableOutput("sys_info_table"),
            type = 6,
            color = "firebrick",
            proxy.height = "180px"
          )
        ),
        card(
          card_header(h4(icon("microchip"), "CodeCarbon Machine Configuration")),
          shinycssloaders::withSpinner(
            shiny::tableOutput("codecarbon_info_table"),
            type = 6,
            color = "firebrick",
            proxy.height = "180px"
          )
        )
      ),
      layout_columns(
        col_widths = 12,
        card(
          full_screen = TRUE,
          card_header(h4(icon("code"), "Detailed R Session Info")),
          pre(textOutput("session_info_text"))
        )
      )
    ),

    # --- TAB 2: Carbon Analysis ---
    nav_panel(
      title = "Carbon Analysis",
      layout_columns(
        col_widths = c(4, 8),

        # Summary Card
        card(
          card_header(h4(icon("leaf"), "Total Impact")),
          value_box(
            title = "Total CO2 Emissions",
            value = textOutput("total_emissions"),
            showcase = icon("cloud"),
            theme = "danger"
          ),
          value_box(
            title = "Energy Consumed",
            value = textOutput("total_energy"),
            showcase = icon("bolt"),
            theme = "warning"
          )
        ),

        # Visualization Card
        card(
          card_header(h4(icon("chart-bar"), "Energy Consumption Breakdown")),
          plotly::plotlyOutput("energy_plot")
        )
      ),

      # Data Table Row
      card(
        card_header(h4(icon("table"), "Raw Emissions Logs")),
        DT::dataTableOutput("emissions_table")
      )
    ),


    # --- TAB 3: Carbon API Calculation ---

    nav_panel(
      title = "Carbon Equivalents",

      tags$div(
        style = "margin-top:-20px;",

        h4("Your computed emissions: ", style = "margin-top:20px;"),

        tags$span(
          textOutput("equivalents", inline = TRUE),
          style = "font-size: 20px; font-weight: bold;"
        ),

        tags$iframe(
          src = "https://www.arbor.eco/tool/carbon-equivalent-calculator?id=811484046",
          width = "100%",
          height = "864px",
          style = "border:none; margin-top:16px;",
          title = "Arbor Carbon Equivalent Calculator"
        )
      )
    )

  )
)


# --- Define Server Logic ---

server <- function(input, output, session) {

  # -----------------------------
  # Clock in sidebar (ONLY ONCE)
  # -----------------------------
  output$current_time <- renderText({
    invalidateLater(1000, session)
    format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z")
  })


  # -----------------------------
  # Tab 1: System / Machine info
  # -----------------------------
  machine_info_data <- get_static_machine_info()

  output$codecarbon_info_table <- renderTable({
    machine_info_data
  },
  striped = TRUE,
  hover = TRUE,
  width = "100%",
  align = "l")

  output$sys_info_table <- renderTable({
    get_system_info()
  },
  striped = TRUE,
  hover = TRUE,
  width = "100%",
  align = "l")

  output$session_info_text <- renderText({
    paste(get_session_info_text(), collapse = "\n")
  })


  # -----------------------------
  # Tab 2: Carbon Analysis
  # -----------------------------
  get_project_root <- function() {
    # 1) RStudio Project root (best for local dev)
    if (requireNamespace("rstudioapi", quietly = TRUE) &&
        rstudioapi::isAvailable()) {
      p <- tryCatch(rstudioapi::getActiveProject(), error = function(e) NULL)
      if (!is.null(p) && nzchar(p)) return(normalizePath(p, winslash = "/"))
    }

    # 2) Git root (great for deployments / containers)
    if (requireNamespace("rprojroot", quietly = TRUE)) {
      p <- tryCatch(
        rprojroot::find_root(rprojroot::is_git_root),
        error = function(e) NULL
      )
      if (!is.null(p) && nzchar(p)) return(normalizePath(p, winslash = "/"))
    }

    # 3) Fallback
    normalizePath(getwd(), winslash = "/")
  }

  emissions_data <- reactive({
    # Anchor the search to the app directory (NOT getwd() alone)
    app_dir <- get_project_root()

    csv_files <- list.files(
      path = app_dir,
      pattern = "^emissions(_r)?\\.csv$",
      recursive = TRUE,
      full.names = TRUE
    )

    validate(
      need(length(csv_files) > 0,
           "emissions_r.csv (or emissions.csv) not found anywhere in the project folder.")
    )

    # If multiple, take the most recently modified
    file_path <- csv_files[which.max(file.info(csv_files)$mtime)]

    df <- read.csv(file_path, stringsAsFactors = FALSE)

    # tidycarbon's uniform schema names the CO2e column emissions_total;
    # CodeCarbon's native schema (legacy files) names it emissions. The app
    # uses the native name downstream, so alias when needed.
    if (!"emissions" %in% names(df) && "emissions_total" %in% names(df)) {
      df$emissions <- df$emissions_total
    }

    # Robust timestamp parsing (won't break if format varies slightly)
    if ("timestamp" %in% names(df)) {
      df$timestamp <- suppressWarnings(as.POSIXct(df$timestamp, tz = "UTC"))
      # If it came in as NA due to parsing, try the expected CodeCarbon format
      if (all(is.na(df$timestamp)) && nrow(df) > 0) {
        df$timestamp <- suppressWarnings(as.POSIXct(
          df$timestamp,
          format = "%Y-%m-%dT%H:%M:%S",
          tz = "UTC"
        ))
      }
    }

    df
  })


  # Data table
  output$emissions_table <- DT::renderDataTable({
    df <- emissions_data()

    # If you have multiple rows, pick the first row (or summarise instead)
    df1 <- df[1, , drop = FALSE]

    df_t <- as.data.frame(t(df1)) |>
      tibble::rownames_to_column("Metric") |>
      select(1, Values = 2)


    DT::datatable(
      df_t,
      rownames = FALSE,
      options = list(scrollX = TRUE, pageLength = 40),
      escape = FALSE
    ) |>
      DT::formatStyle(
        columns = c("Metric", "Values"),
        fontWeight = "bold"
      )
  })


  # Energy breakdown plot
  output$energy_plot <- plotly::renderPlotly({
    df <- emissions_data()

    # Ensure required columns exist
    validate(
      need(all(c("cpu_energy", "gpu_energy", "ram_energy") %in% names(df)),
           "Missing one or more columns: cpu_energy, gpu_energy, ram_energy.")
    )

    plot_df <- df |>
      dplyr::summarise(
        CPU = sum(cpu_energy, na.rm = TRUE),
        GPU = sum(gpu_energy, na.rm = TRUE),
        RAM = sum(ram_energy, na.rm = TRUE)
      ) |>
      tidyr::pivot_longer(
        cols = dplyr::everything(),
        names_to = "Source",
        values_to = "Energy"
      )

    plotly::plot_ly(
      plot_df,
      x = ~Source,
      y = ~Energy,
      type = "bar",
      color = ~Source
    ) |>
      plotly::layout(
        yaxis = list(title = "Energy (kWh)"),
        xaxis = list(title = "")
      )
  })


  # Value boxes: total emissions
  output$total_emissions <- renderText({
    df <- emissions_data()
    validate(need("emissions" %in% names(df), "Column 'emissions' not found in emissions.csv."))
    paste0(round(sum(df$emissions, na.rm = TRUE), 50), " kg eq. CO2")
  })

  # Value boxes: total energy consumed
  output$total_energy <- renderText({
    df <- emissions_data()
    validate(need("energy_consumed" %in% names(df), "Column 'energy_consumed' not found in emissions.csv."))
    paste0(round(sum(df$energy_consumed, na.rm = TRUE), 6), " kWh")
  })

  output$equivalents <- renderText({
    df <- emissions_data()
    validate(need("emissions" %in% names(df), "Column 'emissions' not found in emissions.csv."))
    paste0(round(sum(df$emissions, na.rm = TRUE), 50), " kg eq. CO2")
  })

}


# Run the application
shinyApp(ui = ui, server = server, options = list(launch.browser = TRUE))
