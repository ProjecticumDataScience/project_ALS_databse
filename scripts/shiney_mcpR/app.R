library(shiny)
library(bslib)
library(DT)
library(httr2)
library(jsonlite)

API_URL <- "http://localhost:8000"

# ───────────────────────────────────────────────────────────────────────────
# API helper
# ───────────────────────────────────────────────────────────────────────────

call_api <- function(endpoint,
                     body = list()) {
  
  tryCatch({
    
    resp <- request(API_URL) |>
      req_url_path(endpoint) |>
      req_body_json(body) |>
      req_perform()
    
    fromJSON(
      resp_body_string(resp),
      flatten = TRUE
    )
    
  }, error = function(e) {
    
    data.frame(
      error = e$message
    )
  })
}

# ════════════════════════════════════════════════════════════════════════════
# UI
# ════════════════════════════════════════════════════════════════════════════

ui <- page_sidebar(
  
  title = "ALS Variant Explorer",
  
  theme = bs_theme(
    version = 5,
    bootswatch = "flatly"
  ),
  
  sidebar = sidebar(
    
    h4("Zoeken"),
    
    textInput(
      "gene",
      "Gennaam",
      value = "NEK1"
    ),
    
    actionButton(
      "search",
      "Zoek varianten"
    ),
    
    hr(),
    
    actionButton(
      "summary",
      "Database samenvatting"
    )
  ),
  
  card(
    full_screen = TRUE,
    
    card_header(
      h4("Resultaten")
    ),
    
    DTOutput("table")
  )
)

# ════════════════════════════════════════════════════════════════════════════
# SERVER
# ════════════════════════════════════════════════════════════════════════════

server <- function(input, output, session) {
  
  rv <- reactiveValues(
    data = NULL
  )
  
  observeEvent(input$search, {
    
    rv$data <- call_api(
      "get_variants_by_gene",
      list(
        gene = input$gene,
        limit = 500
      )
    )
  })
  
  observeEvent(input$summary, {
    
    rv$data <- call_api(
      "summarize_database"
    )
  })
  
  output$table <- renderDT({
    
    req(rv$data)
    
    datatable(
      rv$data,
      options = list(
        pageLength = 15,
        scrollX = TRUE
      ),
      rownames = FALSE
    )
  })
}

shinyApp(ui, server)