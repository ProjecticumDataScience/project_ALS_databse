# ─────────────────────────────────────────────────────────────────────────────
# Project ALS  —  Shiny app met MCP server integratie
# Vereiste packages : shiny, bslib, DT, httr2, jsonlite
# Vereist draaiend  : mcpo op localhost:8000  |  Ollama op localhost:11434
# ─────────────────────────────────────────────────────────────────────────────

library(shiny)
library(bslib)
library(DT)
library(httr2)
library(jsonlite)

MCP_URL    <- "http://localhost:8000"
OLLAMA_URL <- "http://localhost:11434"

# ══════════════════════════════════════════════════════════════════════════════
# HELPER FUNCTIES
# ══════════════════════════════════════════════════════════════════════════════

# ── Roep een MCP tool aan via mcpo ───────────────────────────────────────────
call_mcp <- function(tool_name, body = list()) {
  tryCatch({
    resp <- request(MCP_URL) |>
      req_url_path(paste0("/", tool_name)) |>
      req_body_json(body) |>
      req_timeout(30) |>
      req_perform()
    resp_body_string(resp)
  }, error = function(e) {
    toJSON(list(error = e$message), auto_unbox = TRUE)
  })
}

# ── Roep Ollama aan ──────────────────────────────────────────────────────────
call_ollama <- function(prompt, system_prompt = NULL, json_mode = FALSE) {
  body <- list(
    model   = "llama3.1:8b",
    prompt  = prompt,
    stream  = FALSE,
    options = list(
      temperature = if (json_mode) 0.0 else 0.2,
      num_predict = 600
    )
  )
  if (!is.null(system_prompt)) body$system <- system_prompt
  if (json_mode)               body$format <- "json"
  
  tryCatch({
    resp <- request(OLLAMA_URL) |>
      req_url_path("/api/generate") |>
      req_body_json(body) |>
      req_timeout(60) |>
      req_perform()
    resp_body_json(resp)$response
  }, error = function(e) {
    paste("Ollama niet bereikbaar:", e$message)
  })
}

# ── Haal schema op via MCP (eenmalig bij laden) ──────────────────────────────
get_schema_info <- function() {
  tryCatch({
    raw  <- call_mcp("get_schema")
    cols <- fromJSON(raw)
    paste(apply(cols, 1, function(r) paste0(r["name"], " (", r["type"], ")")),
          collapse = ", ")
  }, error = function(e) {
    # Fallback: bekende kolommen van varInfo_synthetic
    paste(
      "varID (TEXT), chr (TEXT), pos (INTEGER), ref (TEXT), alt (TEXT),",
      "gene (TEXT), consequence (TEXT), impact (TEXT),",
      "sift_pred (TEXT), polyphen_pred (TEXT), cadd_phred (REAL),",
      "ALS_1 (INTEGER), ALS_2 (INTEGER), ALS_3 (INTEGER),",
      "ALS_4 (INTEGER), ALS_5 (INTEGER),",
      "Control_1 (INTEGER), Control_2 (INTEGER), Control_3 (INTEGER),",
      "Control_4 (INTEGER), Control_5 (INTEGER)"
    )
  })
}

# Schema wordt één keer geladen bij opstarten
SCHEMA_INFO <- get_schema_info()

# ── Vertaal gebruikersvraag naar tool + parameters ───────────────────────────
# Belangrijk: gen-specifieke vragen gebruiken ALTIJD get_variants_by_gene
# zodat het model nooit zelf SQL schrijft met mogelijk verkeerde kolomnamen.
classify_question <- function(question) {
  sys <- paste0(
    "Output ONLY a JSON object with exactly two keys: 'tool' and 'params'.\n",
    "No explanation. No markdown. No extra keys.\n\n",
    
    "The database table is: varInfo_synthetic\n",
    "Columns: ", SCHEMA_INFO, "\n\n",
    
    "IMPORTANT column names:\n",
    "- Gene name column  : gene   (NOT gene_name, NOT Gene)\n",
    "- Variant ID column : varID  (NOT VAR_id, NOT variant_id)\n",
    "- Impact values     : HIGH, MODERATE, LOW, MODIFIER\n",
    "- Genotype columns  : ALS_1..ALS_5 and Control_1..Control_5\n\n",
    
    "TOOL SELECTION — follow these rules strictly:\n\n",
    
    "1. Any question about a SPECIFIC gene (show, list, hoeveel, count, how many):\n",
    "   -> ALWAYS use get_variants_by_gene, use limit:500 for count questions\n",
    '   {"tool":"get_variants_by_gene","params":{"gene":"NEK1","limit":500}}\n\n',
    
    "2. Which gene has the most variants / top genes / ranking / all genes:\n",
    '   {"tool":"count_variants_by_gene","params":{"top_n":20}}\n\n',
    
    "3. Filter by impact level (HIGH / MODERATE / LOW / MODIFIER):\n",
    '   {"tool":"get_variants_by_impact","params":{"impact":"HIGH","limit":100}}\n\n',
    
    "4. Deleterious / pathogenic / schadelijke varianten:\n",
    '   {"tool":"get_deleterious_variants","params":{"predictor":"SIFT","limit":100}}\n\n',
    
    "5. Database totals / overview / statistics / summary:\n",
    '   {"tool":"summarize_database","params":{}}\n\n',
    
    "6. Chromosome, position, ALS vs Control genotypes, or anything else:\n",
    '   {"tool":"query_variants","params":{"sql":',
    '"SELECT chr, COUNT(*) AS n FROM varInfo_synthetic GROUP BY chr ORDER BY n DESC LIMIT 50"}}\n\n',
    
    "Return ONLY the JSON object, nothing else."
  )
  
  raw <- call_ollama(question, system_prompt = sys, json_mode = TRUE)
  
  tryCatch({
    # Verwijder mogelijke markdown backticks
    clean <- gsub("```json|```", "", raw)
    clean <- trimws(clean)
    
    parsed <- fromJSON(clean, simplifyVector = FALSE)
    
    # Fallback: model gaf query terug in verkeerd formaat
    if (is.null(parsed$tool) && !is.null(parsed$query)) {
      return(list(ok = TRUE, tool = "query_variants",
                  params = list(sql = parsed$query)))
    }
    if (is.null(parsed$tool)) stop("Geen 'tool' sleutel gevonden")
    
    list(ok     = TRUE,
         tool   = parsed$tool,
         params = if (is.null(parsed$params)) list() else parsed$params)
    
  }, error = function(e) {
    list(ok    = FALSE,
         error = paste0("Classificatie mislukt: ", e$message,
                        "\nModel gaf terug: ", raw))
  })
}

# ── Samenvatting van tool-resultaat in het Nederlands ────────────────────────
summarize_result <- function(question, tool_name, result_json, row_count = NULL) {
  sys <- paste(
    "Je bent een ALS-bioinformatica assistent.",
    "Geef een korte, heldere Nederlandse samenvatting (max 2 zinnen).",
    "Gebruik geen SQL, JSON of technisch jargon.",
    "Begin direct met de conclusie.",
    sep = " "
  )
  
  preview <- if (nchar(result_json) > 3000) {
    paste0(substr(result_json, 1, 3000), "\n... [resultaat ingekort]")
  } else {
    result_json
  }
  
  count_hint <- if (!is.null(row_count)) {
    paste0("\nHet exacte aantal gevonden rijen is: ", row_count, ". Noem dit getal in je samenvatting.\n")
  } else ""
  
  prompt <- paste0(
    "Gebruikersvraag: ", question,   "\n",
    "Gebruikte tool:  ", tool_name,  "\n",
    count_hint,
    "Resultaat:\n",      preview,    "\n\n",
    "Geef een korte Nederlandse samenvatting."
  )
  
  call_ollama(prompt, system_prompt = sys)
}

# ── Hulpoperator ─────────────────────────────────────────────────────────────
`%||%` <- function(a, b) if (!is.null(a)) a else b

# ══════════════════════════════════════════════════════════════════════════════
# UI
# ══════════════════════════════════════════════════════════════════════════════

ui <- page_sidebar(
  title = "Project ALS",
  theme = bs_theme(version = 5, bootswatch = "flatly"),
  
  sidebar = sidebar(
    width = 320,
    h4("Variant Assistant"),
    p("Stel vragen over ALS-varianten in de database."),
    hr(),
    
    h5("Voorbeeldvragen"),
    tags$ul(
      tags$li(actionLink("ex1", "Hoeveel varianten zitten er in NEK1?")),
      tags$li(actionLink("ex2", "Toon alle HIGH-impact varianten")),
      tags$li(actionLink("ex3", "Welk gen heeft de meeste varianten?")),
      tags$li(actionLink("ex4", "Hoeveel varianten per chromosoom?")),
      tags$li(actionLink("ex5", "Toon schadelijke varianten (SIFT)"))
    ),
    hr(),
    
    h5("Database"),   p("varInfo_synthetic"),
    h5("Model"),      p("llama3.1:8b"),
    h5("MCP server"),
    p(tags$a("localhost:8000/docs",
             href = "http://localhost:8000/docs", target = "_blank")),
    hr(),
    
    h5("Status"),
    uiOutput("status_ui"),
    hr(),
    
    h5("Schema"),
    div(style = "font-size:0.75em; color:#555; word-break:break-word;",
        uiOutput("schema_ui")),
    hr(),
    
    actionButton("clear_btn", "Gesprek wissen",
                 class = "btn-outline-secondary btn-sm w-100")
  ),
  
  layout_columns(
    col_widths = c(5, 7),
    
    # ── Chat venster ─────────────────────────────────────────────────────────
    card(
      full_screen = TRUE,
      card_header(h4("Chat")),
      div(
        id    = "chat_scroll",
        style = paste(
          "height:520px; overflow-y:auto; padding:12px;",
          "background:#f8f9fa; border:1px solid #dee2e6; border-radius:6px;"
        ),
        uiOutput("chat_ui")
      ),
      div(
        style = "display:flex; gap:8px; margin-top:10px;",
        textInput(
          "user_input", label = NULL, width = "100%",
          placeholder = "Stel een vraag over ALS-varianten..."
        ),
        actionButton("send_btn", "\u2192", class = "btn-primary")
      ),
      uiOutput("loading_ui")
    ),
    
    # ── Resultaten tabel ─────────────────────────────────────────────────────
    card(
      full_screen = TRUE,
      card_header(h4("Resultaten")),
      DTOutput("result_table")
    )
  )
)

# ══════════════════════════════════════════════════════════════════════════════
# SERVER
# ══════════════════════════════════════════════════════════════════════════════

server <- function(input, output, session) {
  
  rv <- reactiveValues(
    messages   = list(),
    last_df    = NULL,
    is_loading = FALSE,
    mcp_ok     = NA
  )
  
  # ── MCP status check bij opstarten ───────────────────────────────────────
  observe({
    tryCatch({
      resp <- request(MCP_URL) |>
        req_url_path("/openapi.json") |>
        req_timeout(4) |>
        req_perform()
      rv$mcp_ok <- resp_status(resp) == 200
    }, error = function(e) {
      rv$mcp_ok <- FALSE
    })
  })
  
  output$status_ui <- renderUI({
    if (is.na(rv$mcp_ok)) {
      div(style = "color:#888;", "\u25CF Controleren...")
    } else if (rv$mcp_ok) {
      div(style = "color:green; font-weight:bold;", "\u25CF MCP verbonden")
    } else {
      div(style = "color:red; font-weight:bold;",
          "\u25CF MCP niet bereikbaar", br(),
          tags$small("Start de bash launcher opnieuw"))
    }
  })
  
  output$schema_ui <- renderUI({ p(SCHEMA_INFO) })
  
  # ── Voorbeeldvragen ───────────────────────────────────────────────────────
  observeEvent(input$ex1, updateTextInput(session, "user_input",
                                          value = "Hoeveel varianten zitten er in NEK1?"))
  observeEvent(input$ex2, updateTextInput(session, "user_input",
                                          value = "Toon alle HIGH-impact varianten"))
  observeEvent(input$ex3, updateTextInput(session, "user_input",
                                          value = "Welk gen heeft de meeste varianten?"))
  observeEvent(input$ex4, updateTextInput(session, "user_input",
                                          value = "Hoeveel varianten zijn er per chromosoom?"))
  observeEvent(input$ex5, updateTextInput(session, "user_input",
                                          value = "Toon schadelijke varianten voorspeld door SIFT"))
  
  # ── Gesprek wissen ────────────────────────────────────────────────────────
  observeEvent(input$clear_btn, {
    rv$messages <- list()
    rv$last_df  <- NULL
  })
  
  # ── Verzendfunctie ────────────────────────────────────────────────────────
  handle_send <- function() {
    question <- trimws(input$user_input)
    req(nchar(question) > 0)
    updateTextInput(session, "user_input", value = "")
    
    rv$messages   <- c(rv$messages, list(list(role = "user", text = question)))
    rv$is_loading <- TRUE
    
    tryCatch({
      
      # Stap 1: classificeer vraag naar tool + params
      cl <- classify_question(question)
      
      if (!cl$ok) {
        rv$messages <- c(rv$messages, list(list(
          role = "assistant",
          text = paste("Kon de vraag niet verwerken:", cl$error)
        )))
        rv$is_loading <- FALSE
        return()
      }
      
      tool   <- cl$tool
      params <- if (is.null(cl$params)) list() else as.list(cl$params)
      
      # Stap 2: roep MCP tool aan via mcpo
      raw_result <- call_mcp(tool, params)
      
      # Stap 3: parse resultaat voor de tabel
      rv$last_df <- tryCatch({
        parsed <- fromJSON(raw_result, flatten = TRUE)
        if (is.data.frame(parsed)) {
          parsed
        } else if (is.list(parsed)) {
          # Geneste lijst (bijv. summarize_database) → plat maken
          flat <- unlist(parsed, recursive = TRUE)
          data.frame(sleutel = names(flat),
                     waarde  = as.character(flat),
                     stringsAsFactors = FALSE)
        } else {
          data.frame(resultaat = as.character(parsed))
        }
      }, error = function(e) {
        data.frame(resultaat = raw_result)
      })
      
      # Stap 4: tel rijen voor gen-queries en geef exact aantal mee
      row_count <- if (tool == "get_variants_by_gene" && !is.null(rv$last_df)) {
        nrow(rv$last_df)
      } else NULL
      
      # Stap 5: laat Ollama een samenvatting maken met het exacte aantal
      summary_text <- summarize_result(question, tool, raw_result, row_count)
      
      # Voeg het exacte aantal toe als vetgedrukte regel onder de samenvatting
      if (!is.null(row_count)) {
        gene_name <- if (!is.null(params$gene)) params$gene else "dit gen"
        summary_text <- paste0(
          summary_text,
          "\n\nAantal varianten in ", gene_name, ": ", row_count
        )
      }
      
      rv$messages <- c(rv$messages, list(list(
        role = "assistant",
        text = summary_text,
        tool = tool
      )))
      
    }, error = function(e) {
      rv$messages <- c(rv$messages, list(list(
        role = "assistant",
        text = paste("Fout:", e$message)
      )))
    })
    
    rv$is_loading <- FALSE
  }
  
  observeEvent(input$send_btn, handle_send())
  
  # ── Render chatberichten ──────────────────────────────────────────────────
  output$chat_ui <- renderUI({
    msgs <- rv$messages
    if (length(msgs) == 0) {
      return(p(
        style = "color:#999; font-style:italic; text-align:center; margin-top:40px;",
        "Stel een vraag over de ALS-variant database..."
      ))
    }
    
    msg_els <- lapply(msgs, function(m) {
      if (m$role == "user") {
        div(
          style = paste(
            "background:#0d6efd; color:white; padding:10px 14px;",
            "border-radius:18px 18px 4px 18px;",
            "margin:6px 0 6px 50px; text-align:right;"
          ),
          m$text
        )
      } else {
        tool_badge <- if (!is.null(m$tool)) {
          tags$small(
            style = "color:#666; display:block; margin-bottom:4px;",
            paste0("\U0001F527 ", m$tool)
          )
        }
        # Render **bold** markdown als HTML
        rendered_text <- HTML(gsub(
          "\\*\\*(.*?)\\*\\*", "<strong>\\1</strong>", m$text
        ))
        div(
          style = paste(
            "background:white; border:1px solid #dee2e6;",
            "padding:10px 14px; border-radius:18px 18px 18px 4px;",
            "margin:6px 50px 6px 0; white-space:pre-wrap;"
          ),
          tool_badge,
          rendered_text
        )
      }
    })
    
    tags$div(
      msg_els,
      tags$script(
        "var el = document.getElementById('chat_scroll');
         if (el) el.scrollTop = el.scrollHeight;"
      )
    )
  })
  
  # ── Loading indicator ─────────────────────────────────────────────────────
  output$loading_ui <- renderUI({
    if (rv$is_loading) {
      div(
        style = "color:#0d6efd; font-style:italic; font-size:0.85em; margin-top:4px;",
        "\u23F3 Analyseren via MCP..."
      )
    }
  })
  
  # ── Resultaten tabel ──────────────────────────────────────────────────────
  output$result_table <- renderDT({
    req(!is.null(rv$last_df))
    datatable(
      rv$last_df,
      options  = list(pageLength = 15, scrollX = TRUE, dom = "frtip"),
      rownames = FALSE,
      class    = "table-sm table-striped"
    )
  })
}

shinyApp(ui, server)