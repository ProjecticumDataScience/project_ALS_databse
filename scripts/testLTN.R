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

gdb_conn <- gdb(
  rvat_example("rvatData.gdb")
)

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
# QUERYCHAT OBJECT
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
    
    h4("Variant Assistant"),
    
    p(
      "Ask questions about ALS variants in the database."
    ),
    
    hr(),
    
    h5("Example Questions"),
    
    tags$ul(
      tags$li("How many variants are in NEK1?"),
      tags$li("Show all high-impact variants"),
      tags$li("Which gene contains the most variants?"),
      tags$li("How many variants are predicted deleterious by SIFT?")
    ),
    
    hr(),
    
    h5("Database"),
    p("varInfo_synthetic")
  ),
  
  layout_columns(
    
    col_widths = c(8, 4),
    
    # ─────────────────────────────────────────────
    # CHAT PANEL
    # ─────────────────────────────────────────────
    
    card(
      full_screen = TRUE,
      
      card_header(
        h4("Chat")
      ),
      
      div(
        style = "
          height:750px;
          overflow-y:auto;
          padding:10px;
        ",
        
        qc$ui()
      )
    ),
    
    # ─────────────────────────────────────────────
    # INFO PANEL
    # ─────────────────────────────────────────────
    
    card(
      full_screen = TRUE,
      
      card_header(
        h4("Information")
      ),
      
      h5("Model"),
      p("llama3.1:8b"),
      
      hr(),
      
      h5("Connected Database"),
      p("rvatData.gdb"),
      
      hr(),
      
      h5("Table"),
      p("varInfo_synthetic"),
      
      hr(),
      
      h5("Status"),
      
      div(
        style = "
          color:green;
          font-weight:bold;
        ",
        
        "Connected"
      )
    )
  )
)

# ─────────────────────────────────────────────────────
# SERVER
# ─────────────────────────────────────────────────────

server <- function(input, output, session) {
  
  qc$server()
}

# ─────────────────────────────────────────────────────
# RUN APP
# ─────────────────────────────────────────────────────

shinyApp(ui, server)