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
OLLAMA_MODEL <- "llama3.1:8b"

# ══════════════════════════════════════════════════════════════════════════════
# HELPER FUNCTIES
# ══════════════════════════════════════════════════════════════════════════════

`%||%` <- function(a, b) if (!is.null(a)) a else b

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
    model   = OLLAMA_MODEL,
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
      req_timeout(90) |>
      req_perform()
    resp_body_json(resp)$response
  }, error = function(e) {
    paste("Ollama niet bereikbaar:", e$message)
  })
}

# ── Beschikbare tools (moeten overeenkomen met server.py) ────────────────────
TOOL_DESCRIPTIONS <- paste(
  "Beschikbare tools en wanneer te gebruiken:\n",
  "1. get_variants_by_gene   — vraag naar varianten in een specifiek gen (bijv. NEK1, SOD1)",
  "   params: {\"gene\": \"GENNAAM\", \"limit\": 500}\n",
  "2. count_variants_by_gene — welk gen heeft de meeste varianten / top genen",
  "   params: {\"top_n\": 20}\n",
  "3. get_variants_by_impact — filter op HIGH of MODERATE impact",
  "   params: {\"impact\": \"HIGH\", \"limit\": 100}\n",
  "4. get_deleterious_variants — schadelijke varianten via SIFT of PolyPhen",
  "   params: {\"predictor\": \"SIFT\", \"limit\": 100}\n",
  "5. summarize_database      — database overzicht / statistieken / samenvatting",
  "   params: {}\n",
  "6. get_carriers_by_gene    — dragers in ALS of Control groep voor een gen",
  "   params: {\"gene\": \"GENNAAM\", \"group\": \"ALS\"}\n",
  "7. run_query               — vrije SELECT query voor alles anders",
  "   params: {\"sql\": \"SELECT ...\"}\n",
  sep = ""
)

# ── Vertaal gebruikersvraag naar tool + parameters ───────────────────────────
classify_question <- function(question) {
  sys <- paste0(
    "Output ONLY a valid JSON object with exactly two keys: 'tool' and 'params'.\n",
    "No explanation. No markdown. No extra text. No backticks.\n\n",
    
    TOOL_DESCRIPTIONS, "\n",
    
    "REGELS:\n",
    "- Gennamen zijn altijd hoofdletters: NEK1, SOD1, C9orf72, FUS, TARDBP, TBK1\n",
    "- Voor telvragen over een gen gebruik limit:500\n",
    "- impact waarden zijn alleen 'HIGH' of 'MODERATE' (nooit 'HOOG' of 'LAAG')\n",
    "- predictor waarden zijn 'SIFT' of 'PolyPhen'\n",
    "- group waarden zijn 'ALS' of 'Control'\n\n",
    
    "VOORBEELDEN:\n",
    "Vraag: 'Hoeveel varianten zitten er in NEK1?'\n",
    "{\"tool\":\"get_variants_by_gene\",\"params\":{\"gene\":\"NEK1\",\"limit\":500}}\n\n",
    "Vraag: 'Welk gen heeft de meeste varianten?'\n",
    "{\"tool\":\"count_variants_by_gene\",\"params\":{\"top_n\":20}}\n\n",
    "Vraag: 'Toon alle HIGH-impact varianten'\n",
    "{\"tool\":\"get_variants_by_impact\",\"params\":{\"impact\":\"HIGH\",\"limit\":100}}\n\n",
    "Vraag: 'Toon schadelijke varianten via SIFT'\n",
    "{\"tool\":\"get_deleterious_variants\",\"params\":{\"predictor\":\"SIFT\",\"limit\":100}}\n\n",
    "Vraag: 'Geef een overzicht van de database'\n",
    "{\"tool\":\"summarize_database\",\"params\":{}}\n\n",
    "Vraag: 'Hoeveel varianten per chromosoom?'\n",
    "{\"tool\":\"run_query\",\"params\":{\"sql\":\"SELECT CHROM, COUNT(*) AS n FROM varInfo_synthetic GROUP BY CHROM ORDER BY n DESC\"}}\n\n",
    "Vraag: 'Welke ALS-patiënten zijn drager van een NEK1-variant?'\n",
    "{\"tool\":\"get_carriers_by_gene\",\"params\":{\"gene\":\"NEK1\",\"group\":\"ALS\"}}\n\n",
    
    "Geef ALLEEN het JSON object terug voor deze vraag:\n",
    question
  )
  
  raw <- call_ollama(question, system_prompt = sys, json_mode = TRUE)
  
  tryCatch({
    # Verwijder mogelijke markdown-omhulling
    clean <- gsub("```json|```", "", raw)
    clean <- trimws(clean)
    
    # Pak het eerste JSON object als er meer tekst omheen staat
    json_match <- regmatches(clean, regexpr("\\{.*\\}", clean, perl = TRUE))
    if (length(json_match) > 0) clean <- json_match
    
    parsed <- fromJSON(clean, simplifyVector = FALSE)
    
    # Fallback: model gebruikte 'query' in plaats van 'sql'
    if (!is.null(parsed$tool) && parsed$tool == "query_variants" &&
        !is.null(parsed$params$query)) {
      parsed$tool <- "run_query"
      parsed$params$sql <- parsed$params$query
      parsed$params$query <- NULL
    }
    
    if (is.null(parsed$tool)) stop("Geen 'tool' sleutel gevonden in: ", clean)
    
    list(
      ok     = TRUE,
      tool   = parsed$tool,
      params = if (is.null(parsed$params)) list() else parsed$params
    )
    
  }, error = function(e) {
    list(
      ok    = FALSE,
      error = paste0("Classificatie mislukt: ", e$message, "\nModel gaf: ", raw)
    )
  })
}

# ── Samenvatting van tool-resultaat in het Nederlands ────────────────────────
summarize_result <- function(question, tool_name, result_json, row_count = NULL) {
  sys <- paste(
    "Je bent een ALS-bioinformatica assistent.",
    "Geef een korte, heldere Nederlandse samenvatting (max 3 zinnen).",
    "Gebruik geen SQL, JSON of technisch jargon.",
    "Begin direct met de conclusie.",
    "Als je een exact aantal weet, noem dat dan altijd.",
    sep = " "
  )
  
  preview <- if (nchar(result_json) > 3000) {
    paste0(substr(result_json, 1, 3000), "\n... [resultaat ingekort]")
  } else {
    result_json
  }
  
  count_hint <- if (!is.null(row_count)) {
    paste0("\nHet exacte aantal gevonden rijen is: ", row_count,
           ". Noem dit exacte getal in je samenvatting.\n")
  } else ""
  
  prompt <- paste0(
    "Gebruikersvraag: ", question,  "\n",
    "Gebruikte tool:  ", tool_name, "\n",
    count_hint,
    "Resultaat:\n",     preview,    "\n\n",
    "Geef een korte Nederlandse samenvatting."
  )
  
  call_ollama(prompt, system_prompt = sys)
}

# ══════════════════════════════════════════════════════════════════════════════
# UI
# ══════════════════════════════════════════════════════════════════════════════

ui <- page_sidebar(
  title = "Project ALS — Variant Assistent",
  theme = bs_theme(version = 5, bootswatch = "flatly"),
  
  # Enter-toets stuurt bericht
  tags$head(tags$script(HTML(
    "$(document).on('keypress', '#user_input', function(e) {
       if (e.which == 13) { $('#send_btn').click(); }
     });"
  ))),
  
  sidebar = sidebar(
    width = 300,
    h4("Variant Assistent"),
    p("Stel vragen over ALS-varianten in de database."),
    hr(),
    
    h5("Voorbeeldvragen"),
    tags$ul(
      tags$li(actionLink("ex1", "Hoeveel varianten zitten er in NEK1?")),
      tags$li(actionLink("ex2", "Toon alle HIGH-impact varianten")),
      tags$li(actionLink("ex3", "Welk gen heeft de meeste varianten?")),
      tags$li(actionLink("ex4", "Hoeveel varianten per chromosoom?")),
      tags$li(actionLink("ex5", "Toon schadelijke varianten (SIFT)")),
      tags$li(actionLink("ex6", "Geef een overzicht van de database")),
      tags$li(actionLink("ex7", "Welke ALS dragers zijn er in SOD1?"))
    ),
    hr(),
    
    h5("Verbindingsstatus"),
    uiOutput("status_ui"),
    hr(),
    
    h5("Instellingen"),
    div(style = "font-size:0.85em;",
        tags$b("Database:"),   p("varInfo_synthetic"),
        tags$b("Model:"),      p(OLLAMA_MODEL),
        tags$b("MCP server:"),
        p(tags$a("localhost:8000/docs",
                 href = "http://localhost:8000/docs", target = "_blank"))
    ),
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
          placeholder = "Stel een vraag... (Enter of → om te versturen)"
        ),
        actionButton("send_btn", "→", class = "btn-primary")
      ),
      uiOutput("loading_ui")
    ),
    
    # ── Resultaten tabel ─────────────────────────────────────────────────────
    card(
      full_screen = TRUE,
      card_header(
        div(style = "display:flex; justify-content:space-between; align-items:center;",
            h4("Resultaten", style = "margin:0;"),
            uiOutput("row_count_ui"))
      ),
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
    mcp_ok     = NA,
    row_count  = NULL
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
      div(style = "color:#888;", "● Controleren...")
    } else if (rv$mcp_ok) {
      div(style = "color:green; font-weight:bold;", "● MCP verbonden")
    } else {
      tagList(
        div(style = "color:red; font-weight:bold;", "● MCP niet bereikbaar"),
        tags$small("Start start_services.sh opnieuw")
      )
    }
  })
  
  output$row_count_ui <- renderUI({
    req(!is.null(rv$row_count))
    tags$small(
      style = "color:#666;",
      paste0(rv$row_count, " rijen")
    )
  })
  
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
  observeEvent(input$ex6, updateTextInput(session, "user_input",
                                          value = "Geef een overzicht van de database"))
  observeEvent(input$ex7, updateTextInput(session, "user_input",
                                          value = "Welke ALS dragers zijn er in SOD1?"))
  
  # ── Gesprek wissen ────────────────────────────────────────────────────────
  observeEvent(input$clear_btn, {
    rv$messages   <- list()
    rv$last_df    <- NULL
    rv$row_count  <- NULL
  })
  
  # ── Verzendfunctie ────────────────────────────────────────────────────────
  handle_send <- function() {
    question <- trimws(input$user_input)
    req(nchar(question) > 0)
    updateTextInput(session, "user_input", value = "")
    
    rv$messages   <- c(rv$messages, list(list(role = "user", text = question)))
    rv$is_loading <- TRUE
    rv$row_count  <- NULL
    
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
      
      # Controleer op fout in resultaat
      result_check <- tryCatch(fromJSON(raw_result, simplifyVector = FALSE), error = function(e) NULL)
      if (!is.null(result_check) && !is.null(result_check$error)) {
        rv$messages <- c(rv$messages, list(list(
          role = "assistant",
          text = paste0("MCP fout bij tool '", tool, "': ", result_check$error,
                        "\n\nControleer of de toolnaam klopt en de server draait.")
        )))
        rv$is_loading <- FALSE
        return()
      }
      
      # Stap 3: parse resultaat voor de tabel
      rv$last_df <- tryCatch({
        parsed <- fromJSON(raw_result, flatten = TRUE)
        if (is.data.frame(parsed)) {
          parsed
        } else if (is.list(parsed) && length(parsed) > 0) {
          flat <- unlist(parsed, recursive = TRUE)
          data.frame(
            sleutel = names(flat),
            waarde  = as.character(unname(flat)),
            stringsAsFactors = FALSE
          )
        } else {
          data.frame(resultaat = as.character(raw_result))
        }
      }, error = function(e) {
        data.frame(resultaat = raw_result)
      })
      
      # Stap 4: sla rijenaantal op
      rv$row_count <- nrow(rv$last_df)
      
      # Stap 5: samenvatting via Ollama
      summary_text <- summarize_result(question, tool, raw_result, rv$row_count)
      
      # Voeg het exacte aantal toe onder de samenvatting
      gene_name <- params$gene %||% NULL
      if (!is.null(gene_name)) {
        summary_text <- paste0(
          summary_text,
          "\n\n**Aantal gevonden varianten in ", gene_name, ": ", rv$row_count, "**"
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
        text = paste("Onverwachte fout:", e$message)
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
            paste0("🔧 ", m$tool)
          )
        }
        rendered_text <- HTML(gsub(
          "\\*\\*(.*?)\\*\\*", "<strong>\\1</strong>",
          gsub("\n", "<br>", m$text)
        ))
        div(
          style = paste(
            "background:white; border:1px solid #dee2e6;",
            "padding:10px 14px; border-radius:18px 18px 18px 4px;",
            "margin:6px 50px 6px 0;"
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
        "⏳ Analyseren via MCP..."
      )
    }
  })
  
  # ── Resultaten tabel ──────────────────────────────────────────────────────
  output$result_table <- renderDT({
    req(!is.null(rv$last_df))
    datatable(
      rv$last_df,
      options  = list(
        pageLength = 15,
        scrollX    = TRUE,
        dom        = "frtip",
        language   = list(
          search      = "Zoeken:",
          info        = "Rijen _START_ tot _END_ van _TOTAL_",
          paginate    = list(previous = "Vorige", `next` = "Volgende")
        )
      ),
      rownames = FALSE,
      class    = "table-sm table-striped table-hover"
    )
  })
}

shinyApp(ui, server)