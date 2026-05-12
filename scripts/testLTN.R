library(shiny)
library(bslib)
library(shinycssloaders)
library(DT)

library(querychat)
library(rvat)
library(ellmer)

# ─────────────────────────────────────────────────────
# DATABASE
# ─────────────────────────────────────────────────────

gdb_conn <- gdb(rvat_example("rvatData.gdb"))

# ─────────────────────────────────────────────────────
# LOCAL LLM
# ─────────────────────────────────────────────────────

client <- chat_ollama(
  model = "llama3.1:8b",
  params = ellmer::params(
    temperature = 0.1,
    num_predict = 200
  )
)

# ─────────────────────────────────────────────────────
# QUERYCHAT
# ─────────────────────────────────────────────────────

qc <- QueryChat$new(
  data_source = gdb_conn,
  table_name = "varInfo_synthetic",
  client = client
)

# ─────────────────────────────────────────────────────
# UI
# ─────────────────────────────────────────────────────

ui <- page_sidebar(
  
  title = "Project ALS",
  
  theme = bs_theme(
    version = 5,
    bootswatch = "flatly"
  ),
  
  sidebar = sidebar(
    
    width = 350,
    
    h4("Ask a Question"),
    
    textAreaInput(
      inputId = "question",
      label = NULL,
      placeholder = "Example:\nHow many high-impact variants are in SOD1?",
      rows = 5
    ),
    
    actionButton("submit", "Run Query", class = "btn-primary"),
    br(), br(),
    actionButton("reset_chat", "Reset Conversation", class = "btn-danger"),
    
    hr(),
    
    h5("Example Questions"),
    tags$ul(
      tags$li("How many variants are in NEK1?"),
      tags$li("Show all high-impact variants"),
      tags$li("Which gene contains the most variants?"),
      tags$li("How many variants are predicted deleterious by SIFT?")
    )
  ),
  
  layout_columns(
    
    col_widths = c(5, 7),
    
    card(
      full_screen = TRUE,
      card_header(h4("Chat")),
      
      div(
        style = "height:700px; overflow-y:auto; padding:15px; background:#f8f9fa;",
        shinycssloaders::withSpinner(uiOutput("chat_history"))
      )
    ),
    
    card(
      full_screen = TRUE,
      card_header(h4("Debug Information")),
      
      h5("Available QueryChat methods"),
      verbatimTextOutput("methods_output"),
      
      h5("Last response"),
      verbatimTextOutput("raw_response")
    )
  )
)

# ─────────────────────────────────────────────────────
# SERVER
# ─────────────────────────────────────────────────────

server <- function(input, output, session) {
  
  rv <- reactiveValues(messages = list(), raw_response = NULL)
  
  # Methods debug
  output$methods_output <- renderPrint({
    names(qc)
  })
  
  # RUN QUERY
  observeEvent(input$submit, {
    
    req(input$question)
    
    response <- tryCatch(
      {
        # fIX: correct QueryChat call
        qc$ui$chat(input$question)
      },
      error = function(e) {
        paste("ERROR:", e$message)
      }
    )
    
    rv$raw_response <- response
    
    rv$messages <- append(rv$messages, list(
      list(
        question = input$question,
        answer = paste(response, collapse = "\n")
      )
    ))
    
    updateTextAreaInput(session, "question", value = "")
  })
  
  # RESET
  observeEvent(input$reset_chat, {
    rv$messages <- list()
    rv$raw_response <- NULL
  })
  
  # CHAT OUTPUT
  output$chat_history <- renderUI({
    
    if (length(rv$messages) == 0) {
      return(
        div(
          style = "text-align:center; margin-top:50px; color:grey;",
          h4("No conversation yet"),
          p("Ask a question to begin.")
        )
      )
    }
    
    tagList(
      lapply(rv$messages, function(msg) {
        
        div(
          style = "margin-bottom:25px;",
          
          div(
            style = "background:#457B9D; color:white; padding:12px; border-radius:12px; margin-bottom:10px;",
            tags$b("You"), br(), msg$question
          ),
          
          div(
            style = "background:white; border:1px solid #dee2e6; padding:12px; border-radius:12px;",
            tags$b("Assistant"), br(), msg$answer
          )
        )
      })
    )
  })
  
  # RAW OUTPUT
  output$raw_response <- renderPrint({
    rv$raw_response
  })
}

shinyApp(ui, server)