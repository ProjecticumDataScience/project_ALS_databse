# ─────────────────────────────────────────────────────────────────────────────
# Project ALS  —  Variant Assistent (MVP)
# Packages : shiny, bslib, DT, httr2, jsonlite
# Requires : mcpo on localhost:8005  |  Ollama on localhost:11434
# ─────────────────────────────────────────────────────────────────────────────

library(shiny)
library(bslib)
library(DT)
library(httr2)
library(jsonlite)

MCP_URL    <- "http://localhost:8005"
OLLAMA_URL <- "http://localhost:11434"

## ── Load domain knowledge from prompts.txt ───────────────────
## Reads DATA_DESCRIPTION and EXTRA_INSTRUCTIONS at startup.
## Keep prompts.txt in the same folder as app.R.
load_prompts <- function() {
  prompts_file <- file.path(dirname(rstudioapi::getSourceEditorContext()$path),
                            "prompts.txt")
  ## Fallback to working directory if not in RStudio
  if (!file.exists(prompts_file)) {
    prompts_file <- "prompts.txt"
  }
  if (!file.exists(prompts_file)) {
    message("WARNING: prompts.txt not found — using minimal system prompt")
    return(list(data_description = "", extra_instructions = ""))
  }
  raw   <- paste(readLines(prompts_file, warn = FALSE), collapse = "\n")
  parts <- strsplit(raw, "===EXTRA_INSTRUCTIONS===")[[1]]
  data_desc  <- trimws(sub(".*===DATA_DESCRIPTION===\n", "", parts[1]))
  extra_inst <- if (length(parts) > 1) trimws(parts[2]) else ""
  ## Trim extra_instructions to rules only — skip long SQL examples
  ## (keeps app prompts concise for faster responses)
  extra_short <- strsplit(extra_inst, "EXAMPLES:")[[1]][1]
  list(
    data_description   = data_desc,
    extra_instructions = trimws(extra_short %||% extra_inst)
  )
}

PROMPTS <- load_prompts()

AVAILABLE_MODELS <- list(
  "Single LLM (llama3.1:8b)"       = list(mode = "single", orch = "llama3.1:8b", sub = NULL),
  "Single LLM (mistral)"            = list(mode = "single", orch = "mistral",     sub = NULL),
  "Two LLM: llama3.1 → duckdb-nsql" = list(mode = "dual",   orch = "llama3.1:8b", sub = "duckdb-nsql"),
  "Two LLM: llama3.1 → llama3.1"   = list(mode = "dual",   orch = "llama3.1:8b", sub = "llama3.1:8b")
)

# ══════════════════════════════════════════════════════════════════════════════
# HELPERS
# ══════════════════════════════════════════════════════════════════════════════

`%||%` <- function(a, b) if (!is.null(a)) a else b

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

call_ollama <- function(prompt, system_prompt = NULL,
                        model = "llama3.1:8b",
                        json_mode = FALSE,
                        num_predict = 600) {
  body <- list(
    model   = model,
    prompt  = prompt,
    stream  = FALSE,
    options = list(
      temperature = if (json_mode) 0.0 else 0.2,
      num_predict = num_predict
    )
  )
  if (!is.null(system_prompt)) body$system <- system_prompt
  if (json_mode)               body$format <- "json"
  
  tryCatch({
    resp <- request(OLLAMA_URL) |>
      req_url_path("/api/generate") |>
      req_body_json(body) |>
      req_timeout(120) |>
      req_perform()
    resp_body_json(resp)$response
  }, error = function(e) {
    paste("Ollama niet bereikbaar:", e$message)
  })
}

TOOL_DESCRIPTIONS <- paste(
  "Beschikbare tools:\n",
  "1. count_variants_in_gene      — aantal varianten in een gen | params: {gene}\n",
  "2. get_high_impact_variants_in_gene — high-impact + CADD > drempel | params: {gene, cadd_min}\n",
  "3. count_sift_deleterious_in_gene  — SIFT deleterious in gen | params: {gene}\n",
  "4. get_high_impact_homozygous_ALS  — homozygoot in ALS | params: {}\n",
  "5. get_top_deleterious_in_gene     — top N deleterieus | params: {gene, top_n}\n",
  "6. get_highest_af_variant          — hoogste allelfrequentie | params: {}\n",
  "7. get_average_af_by_impact        — gemiddelde AF per impact | params: {}\n",
  "8. get_burden_cases_vs_controls    — totale burden cases vs controls | params: {}\n",
  "9. summarize_variants_by_gene      — samenvatting per gen | params: {min_variants, order_by}\n",
  "10. get_carriers_by_gene           — dragers in ALS/Control | params: {gene, group}\n",
  "11. get_database_limitations       — wat is NIET beschikbaar | params: {}\n",
  "12. summarize_database             — database statistieken | params: {}\n",
  "13. run_query                      — vrije SELECT query | params: {sql}\n",
  sep = ""
)

classify_question <- function(question, orch_model = "llama3.1:8b") {
  sys <- paste0(
    ## Domain knowledge from prompts.txt
    PROMPTS$data_description, "\n\n",
    PROMPTS$extra_instructions, "\n\n",
    ## Tool routing instructions
    "Output ONLY a valid JSON object with exactly two keys: 'tool' and 'params'.\n",
    "No explanation. No markdown. No extra text. No backticks.\n\n",
    TOOL_DESCRIPTIONS, "\n",
    "REGELS:\n",
    "- Gennamen altijd hoofdletters: NEK1, SOD1, TARDBP, FUS, ABCA4\n",
    "- Voor onbeantwoordbare vragen (leeftijd, geslacht, ClinVar, populatie-AF): ",
    "gebruik get_database_limitations\n",
    "- Voor vage vragen ('belangrijkste'): gebruik get_database_limitations\n\n",
    "Geef ALLEEN het JSON object terug voor:\n", question
  )
  
  raw <- call_ollama(question, system_prompt = sys,
                     model = orch_model, json_mode = TRUE)
  
  tryCatch({
    clean <- gsub("```json|```", "", raw)
    clean <- trimws(clean)
    start <- regexpr("\\{", clean)[[1]]
    end   <- tail(gregexpr("\\}", clean)[[1]], 1)
    if (start > 0 && end > start) clean <- substr(clean, start, end)
    parsed <- fromJSON(clean, simplifyVector = FALSE)
    if (is.null(parsed$tool)) stop("Geen 'tool' sleutel gevonden")
    list(ok = TRUE, tool = parsed$tool,
         params = if (is.null(parsed$params)) list() else parsed$params)
  }, error = function(e) {
    list(ok = FALSE, error = paste0("Classificatie mislukt: ", e$message,
                                    "\nModel gaf: ", raw))
  })
}

summarize_result <- function(question, tool_name, result_json,
                             row_count = NULL, orch_model = "llama3.1:8b") {
  sys <- paste0(
    PROMPTS$data_description, "\n\n",
    "Je bent een ALS-bioinformatica assistent. ",
    "Geef een korte, heldere Nederlandse samenvatting (max 3 zinnen). ",
    "Gebruik geen SQL, JSON of technisch jargon. ",
    "Begin direct met de conclusie. ",
    "Als je een exact aantal weet, noem dat dan altijd. ",
    "Gebruik de schema-informatie hierboven om de resultaten correct te interpreteren."
  )
  
  preview <- if (nchar(result_json) > 3000) {
    paste0(substr(result_json, 1, 3000), "\n... [resultaat ingekort]")
  } else result_json
  
  count_hint <- if (!is.null(row_count)) {
    paste0("\nHet exacte aantal gevonden rijen is: ", row_count,
           ". Noem dit exacte getal.\n")
  } else ""
  
  prompt <- paste0(
    "Gebruikersvraag: ", question,  "\n",
    "Gebruikte tool:  ", tool_name, "\n",
    count_hint,
    "Resultaat:\n",     preview,    "\n\n",
    "Geef een korte Nederlandse samenvatting."
  )
  
  call_ollama(prompt, system_prompt = sys, model = orch_model)
}

## ── Dual pipeline: orchestrator → subagent → mcpo → summarise ─────────────
run_dual_pipeline <- function(question, orch_model, sub_model,
                              progress_fn = NULL) {
  
  ## Step 1: orchestrator classifies
  if (!is.null(progress_fn)) progress_fn("Orchestrator interpreteert vraag...", 1)
  cl <- classify_question(question, orch_model = orch_model)
  
  if (!cl$ok) return(list(
    ok = FALSE, text = paste("Classificatie mislukt:", cl$error),
    tool = NULL, df = NULL
  ))
  
  tool   <- cl$tool
  params <- if (is.null(cl$params)) list() else as.list(cl$params)
  
  ## Step 2: subagent refines if SQL is needed
  if (tool == "run_query" && !is.null(params$sql)) {
    if (!is.null(progress_fn)) progress_fn("Subagent verfijnt SQL...", 2)
    sub_sys <- paste0(
      PROMPTS$data_description, "\n\n",
      "Je bent een SQL-specialist. Je ontvangt een SQL-query en moet deze ",
      "verbeteren zodat hij correct is voor SQLite op de varInfo_synthetic tabel.\n",
      "Kritieke regels:\n",
      "- Ontbrekende waarden in CADDphred/PolyPhen/SIFT zijn opgeslagen als '.' niet NULL\n",
      "- Gebruik CAST(CADDphred AS REAL) voor numerieke vergelijkingen\n",
      "- Homozygoot: kolom = 2, drager: kolom > 0\n",
      "Geef ALLEEN de verbeterde SQL terug. Geen uitleg."
    )
    improved_sql <- call_ollama(
      paste0("Verbeter deze SQL:\n", params$sql),
      system_prompt = sub_sys,
      model = sub_model,
      num_predict = 300
    )
    improved_sql <- trimws(gsub("```sql|```", "", improved_sql))
    if (grepl("^SELECT", improved_sql, ignore.case = TRUE)) {
      params$sql <- improved_sql
    }
  }
  
  ## Step 3: execute via mcpo
  if (!is.null(progress_fn)) progress_fn("Query uitvoeren via MCP...", 3)
  raw_result <- call_mcp(tool, params)
  
  ## Step 4: orchestrator summarises
  if (!is.null(progress_fn)) progress_fn("Orchestrator formuleert antwoord...", 4)
  
  df <- tryCatch({
    parsed <- fromJSON(raw_result, flatten = TRUE)
    if (is.data.frame(parsed)) parsed
    else if (is.list(parsed) && length(parsed) > 0) {
      flat <- unlist(parsed, recursive = TRUE)
      data.frame(sleutel = names(flat), waarde = as.character(unname(flat)),
                 stringsAsFactors = FALSE)
    } else data.frame(resultaat = as.character(raw_result))
  }, error = function(e) data.frame(resultaat = raw_result))
  
  summary_text <- summarize_result(question, tool, raw_result,
                                   nrow(df), orch_model = orch_model)
  
  list(ok = TRUE, text = summary_text, tool = tool, df = df)
}

## ── Single pipeline ────────────────────────────────────────────────────────
run_single_pipeline <- function(question, model, progress_fn = NULL) {
  
  if (!is.null(progress_fn)) progress_fn("LLM interpreteert en classificeert...", 1)
  cl <- classify_question(question, orch_model = model)
  
  if (!cl$ok) return(list(
    ok = FALSE, text = paste("Classificatie mislukt:", cl$error),
    tool = NULL, df = NULL
  ))
  
  tool   <- cl$tool
  params <- if (is.null(cl$params)) list() else as.list(cl$params)
  
  if (!is.null(progress_fn)) progress_fn("Query uitvoeren via MCP...", 2)
  raw_result <- call_mcp(tool, params)
  
  if (!is.null(progress_fn)) progress_fn("Antwoord formuleren...", 3)
  
  df <- tryCatch({
    parsed <- fromJSON(raw_result, flatten = TRUE)
    if (is.data.frame(parsed)) parsed
    else if (is.list(parsed) && length(parsed) > 0) {
      flat <- unlist(parsed, recursive = TRUE)
      data.frame(sleutel = names(flat), waarde = as.character(unname(flat)),
                 stringsAsFactors = FALSE)
    } else data.frame(resultaat = as.character(raw_result))
  }, error = function(e) data.frame(resultaat = raw_result))
  
  summary_text <- summarize_result(question, tool, raw_result,
                                   nrow(df), orch_model = model)
  
  list(ok = TRUE, text = summary_text, tool = tool, df = df)
}

# ══════════════════════════════════════════════════════════════════════════════
# UI
# ══════════════════════════════════════════════════════════════════════════════

ui <- page_sidebar(
  title = "Project ALS — Variant Assistent",
  theme = bs_theme(
    version    = 5,
    bootswatch = "flatly",
    primary    = "#2A9D8F",
    secondary  = "#457B9D"
  ),
  
  tags$head(
    tags$style(HTML("
      .chat-bubble-user {
        background: #2A9D8F; color: white;
        padding: 10px 14px; border-radius: 18px 18px 4px 18px;
        margin: 6px 0 6px 50px; text-align: right;
      }
      .chat-bubble-bot {
        background: white; border: 1px solid #dee2e6;
        padding: 10px 14px; border-radius: 18px 18px 18px 4px;
        margin: 6px 50px 6px 0;
      }
      .tool-badge { color: #666; font-size: 0.8em; display: block; margin-bottom: 4px; }
      .progress-step { color: #2A9D8F; font-size: 0.85em; margin: 2px 0; }
      .progress-step.done { color: #aaa; }
      #chat_scroll { height: 520px; overflow-y: auto; padding: 12px;
                     background: #f8f9fa; border: 1px solid #dee2e6;
                     border-radius: 6px; }
      .mode-badge { font-size: 0.75em; padding: 2px 8px; border-radius: 12px;
                    font-weight: 600; }
      .mode-single { background: #e8f4f1; color: #2A9D8F; }
      .mode-dual   { background: #e8eef4; color: #457B9D; }
    ")),
    ## Enter to send
    tags$script(HTML(
      "$(document).on('keypress', '#user_input', function(e) {
         if (e.which == 13 && !e.shiftKey) { $('#send_btn').click(); }
       });"
    ))
  ),
  
  sidebar = sidebar(
    width = 310,
    h4("Variant Assistent"),
    p("Stel vragen over ALS-varianten in de database.", style = "color:#666;"),
    hr(),
    
    ## ── Pipeline selector ──────────────────────────────────────────────────
    h5("Pipeline"),
    selectInput(
      "pipeline_select", label = NULL,
      choices = names(AVAILABLE_MODELS),
      selected = names(AVAILABLE_MODELS)[1]
    ),
    uiOutput("pipeline_info_ui"),
    hr(),
    
    ## ── Example questions ──────────────────────────────────────────────────
    h5("Voorbeeldvragen"),
    tags$ul(
      style = "padding-left: 16px;",
      tags$li(actionLink("ex1", "Hoeveel varianten in NEK1?")),
      tags$li(actionLink("ex2", "Toon HIGH-impact varianten")),
      tags$li(actionLink("ex3", "Welk gen heeft de meeste varianten?")),
      tags$li(actionLink("ex4", "Varianten per chromosoom?")),
      tags$li(actionLink("ex5", "Schadelijke varianten (SIFT)")),
      tags$li(actionLink("ex6", "Database overzicht")),
      tags$li(actionLink("ex7", "ALS dragers in SOD1?")),
      tags$li(actionLink("ex8", "Wat is de gemiddelde leeftijd van ALS patiënten?"))
    ),
    hr(),
    
    ## ── Status ────────────────────────────────────────────────────────────
    h5("Status"),
    uiOutput("status_ui"),
    hr(),
    
    actionButton("clear_btn", "Gesprek wissen",
                 class = "btn-outline-secondary btn-sm w-100")
  ),
  
  layout_columns(
    col_widths = c(5, 7),
    
    ## ── Chat panel ──────────────────────────────────────────────────────
    card(
      full_screen = TRUE,
      card_header(
        div(style = "display:flex; justify-content:space-between; align-items:center;",
            h4("Chat", style = "margin:0;"),
            uiOutput("mode_badge_ui"))
      ),
      div(id = "chat_scroll", uiOutput("chat_ui")),
      ## Progress log
      uiOutput("progress_ui"),
      div(
        style = "display:flex; gap:8px; margin-top:10px;",
        textInput("user_input", label = NULL, width = "100%",
                  placeholder = "Stel een vraag... (Enter om te versturen)"),
        actionButton("send_btn", "→", class = "btn-primary")
      )
    ),
    
    ## ── Results table ───────────────────────────────────────────────────
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
    messages     = list(),
    last_df      = NULL,
    is_loading   = FALSE,
    mcp_ok       = NA,
    row_count    = NULL,
    progress_log = character(0)
  )
  
  ## ── MCP health check ───────────────────────────────────────────────────
  observe({
    tryCatch({
      resp <- request(MCP_URL) |>
        req_url_path("/openapi.json") |>
        req_timeout(4) |>
        req_perform()
      rv$mcp_ok <- resp_status(resp) == 200
    }, error = function(e) rv$mcp_ok <- FALSE)
  })
  
  ## ── Current pipeline config ────────────────────────────────────────────
  current_pipeline <- reactive({
    AVAILABLE_MODELS[[input$pipeline_select]]
  })
  
  ## ── Pipeline info display ──────────────────────────────────────────────
  output$pipeline_info_ui <- renderUI({
    p <- current_pipeline()
    if (p$mode == "dual") {
      div(style = "font-size:0.8em; color:#666; margin-top:4px;",
          tags$b("Orchestrator: "), p$orch, tags$br(),
          tags$b("Subagent: "),     p$sub)
    } else {
      div(style = "font-size:0.8em; color:#666; margin-top:4px;",
          tags$b("Model: "), p$orch)
    }
  })
  
  output$mode_badge_ui <- renderUI({
    p <- current_pipeline()
    if (p$mode == "dual") {
      span("Two LLM", class = "mode-badge mode-dual")
    } else {
      span("Single LLM", class = "mode-badge mode-single")
    }
  })
  
  ## ── Status ────────────────────────────────────────────────────────────
  output$status_ui <- renderUI({
    if (is.na(rv$mcp_ok)) {
      div(style = "color:#888;", "● Controleren...")
    } else if (rv$mcp_ok) {
      div(style = "color:#2A9D8F; font-weight:bold;", "● MCP verbonden")
    } else {
      tagList(
        div(style = "color:red; font-weight:bold;", "● MCP niet bereikbaar"),
        tags$small("Start start_services.sh opnieuw")
      )
    }
  })
  
  output$row_count_ui <- renderUI({
    req(!is.null(rv$row_count))
    tags$small(style = "color:#666;", paste0(rv$row_count, " rijen"))
  })
  
  ## ── Progress log ──────────────────────────────────────────────────────
  output$progress_ui <- renderUI({
    if (!rv$is_loading && length(rv$progress_log) == 0) return(NULL)
    steps <- rv$progress_log
    total <- if (current_pipeline()$mode == "dual") 4 else 3
    els <- lapply(seq_along(steps), function(i) {
      is_last <- i == length(steps)
      icon    <- if (!is_last || !rv$is_loading) "✓" else "⟳"
      cls     <- if (!is_last || !rv$is_loading) "progress-step done" else "progress-step"
      div(class = cls, paste(icon, steps[i]))
    })
    div(style = "margin-top:6px; padding: 6px 10px; background:#f0f9f8;
                 border-radius:6px; border-left:3px solid #2A9D8F;",
        els)
  })
  
  ## ── Example questions ─────────────────────────────────────────────────
  ex_map <- list(
    ex1 = "Hoeveel varianten zitten er in NEK1?",
    ex2 = "Toon alle HIGH-impact varianten",
    ex3 = "Welk gen heeft de meeste varianten?",
    ex4 = "Hoeveel varianten zijn er per chromosoom?",
    ex5 = "Toon schadelijke varianten voorspeld door SIFT",
    ex6 = "Geef een overzicht van de database",
    ex7 = "Welke ALS dragers zijn er in SOD1?",
    ex8 = "Wat is de gemiddelde leeftijd van ALS patiënten?"
  )
  for (id in names(ex_map)) {
    local({
      q <- ex_map[[id]]
      observeEvent(input[[id]], updateTextInput(session, "user_input", value = q))
    })
  }
  
  ## ── Clear ────────────────────────────────────────────────────────────
  observeEvent(input$clear_btn, {
    rv$messages     <- list()
    rv$last_df      <- NULL
    rv$row_count    <- NULL
    rv$progress_log <- character(0)
  })
  
  ## ── Send ─────────────────────────────────────────────────────────────
  handle_send <- function() {
    question <- trimws(input$user_input)
    req(nchar(question) > 0, !rv$is_loading)
    updateTextInput(session, "user_input", value = "")
    
    rv$messages     <- c(rv$messages, list(list(role = "user", text = question)))
    rv$is_loading   <- TRUE
    rv$row_count    <- NULL
    rv$progress_log <- character(0)
    
    ## Progress updater
    update_progress <- function(msg, step) {
      rv$progress_log <- c(rv$progress_log, msg)
    }
    
    p <- isolate(current_pipeline())
    
    result <- tryCatch({
      if (p$mode == "dual") {
        run_dual_pipeline(question,
                          orch_model  = p$orch,
                          sub_model   = p$sub,
                          progress_fn = update_progress)
      } else {
        run_single_pipeline(question,
                            model       = p$orch,
                            progress_fn = update_progress)
      }
    }, error = function(e) {
      list(ok = FALSE, text = paste("Onverwachte fout:", e$message),
           tool = NULL, df = NULL)
    })
    
    if (result$ok) {
      rv$last_df   <- result$df
      rv$row_count <- if (!is.null(result$df)) nrow(result$df) else NULL
    }
    
    rv$messages <- c(rv$messages, list(list(
      role  = "assistant",
      text  = result$text,
      tool  = result$tool,
      mode  = p$mode
    )))
    
    rv$is_loading <- FALSE
  }
  
  observeEvent(input$send_btn, handle_send())
  
  ## ── Chat render ───────────────────────────────────────────────────────
  output$chat_ui <- renderUI({
    msgs <- rv$messages
    if (length(msgs) == 0) {
      return(p(style = "color:#999; font-style:italic; text-align:center;
                        margin-top:40px;",
               "Stel een vraag over de ALS-variant database..."))
    }
    
    els <- lapply(msgs, function(m) {
      if (m$role == "user") {
        div(class = "chat-bubble-user", m$text)
      } else {
        mode_label <- if (!is.null(m$mode) && m$mode == "dual") {
          tags$small(class = "tool-badge", "🔗 Two LLM pipeline")
        } else NULL
        tool_badge <- if (!is.null(m$tool)) {
          tags$small(class = "tool-badge", paste0("🔧 ", m$tool))
        } else NULL
        rendered <- HTML(gsub("\\*\\*(.*?)\\*\\*", "<strong>\\1</strong>",
                              gsub("\n", "<br>", m$text)))
        div(class = "chat-bubble-bot", mode_label, tool_badge, rendered)
      }
    })
    
    tags$div(
      els,
      tags$script("var e=document.getElementById('chat_scroll');
                   if(e) e.scrollTop=e.scrollHeight;")
    )
  })
  
  ## ── Results table ────────────────────────────────────────────────────
  output$result_table <- renderDT({
    req(!is.null(rv$last_df))
    datatable(
      rv$last_df,
      options = list(
        pageLength = 15, scrollX = TRUE, dom = "frtip",
        language = list(
          search   = "Zoeken:",
          info     = "Rijen _START_ tot _END_ van _TOTAL_",
          paginate = list(previous = "Vorige", `next` = "Volgende")
        )
      ),
      rownames = FALSE,
      class    = "table-sm table-striped table-hover"
    )
  })
}

shinyApp(ui, server)
