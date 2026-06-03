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
library(shinyjs)

MCP_URL    <- "http://localhost:8005"
OLLAMA_URL <- "http://localhost:11434"

## ── Load domain knowledge from prompts.txt ───────────────────
load_prompts <- function() {
  prompts_file <- file.path(getwd(), "prompts.txt")
  if (!file.exists(prompts_file)) {
    message("WARNING: prompts.txt not found")
    return(list(data_description = "", extra_instructions = ""))
  }
  raw   <- paste(readLines(prompts_file, warn = FALSE), collapse = "\n")
  parts <- strsplit(raw, "===EXTRA_INSTRUCTIONS===")[[1]]
  data_desc  <- trimws(sub(".*===DATA_DESCRIPTION===\n", "", parts[1]))
  extra_inst <- if (length(parts) > 1) trimws(parts[2]) else ""
  extra_short <- strsplit(extra_inst, "EXAMPLES:")[[1]][1]
  list(
    data_description   = data_desc,
    extra_instructions = trimws(extra_short %||% extra_inst)
  )
}

`%||%` <- function(a, b) if (!is.null(a)) a else b

PROMPTS <- load_prompts()

AVAILABLE_MODELS <- list(
  single_llama = list(
    mode  = "single",
    orch  = "llama3.1:8b",
    sub   = NULL,
    label = "Single — llama3.1:8b",
    desc  = "Fast. Good tool selection, weaker free SQL."
  ),
  single_mistral = list(
    mode  = "single",
    orch  = "mistral",
    sub   = NULL,
    label = "Single — mistral",
    desc  = "Faster responses, lower tool-call reliability."
  ),
  dual_duckdb = list(
    mode  = "dual",
    orch  = "llama3.1:8b",
    sub   = "duckdb-nsql",
    label = "Two LLM — llama3.1 + duckdb-nsql",
    desc  = "Best SQL accuracy. Slower due to two model calls."
  ),
  dual_llama = list(
    mode  = "dual",
    orch  = "llama3.1:8b",
    sub   = "llama3.1:8b",
    label = "Two LLM — llama3.1 + llama3.1 ★",
    desc  = "Recommended. Good balance of speed and accuracy."
  )
)

call_mcp <- function(tool_name, body = list()) {
  tryCatch({
    resp <- request(MCP_URL) |>
      req_url_path(paste0("/", tool_name)) |>
      req_body_json(body) |>
      req_timeout(30) |>
      req_perform()
    resp_body_string(resp)
  }, error = function(e) toJSON(list(error = e$message), auto_unbox = TRUE))
}

call_ollama <- function(prompt, system_prompt = NULL, model = "llama3.1:8b",
                        json_mode = FALSE, num_predict = 600) {
  body <- list(model = model, prompt = prompt, stream = FALSE,
               options = list(temperature = if (json_mode) 0.0 else 0.2,
                              num_predict = num_predict))
  if (!is.null(system_prompt)) body$system <- system_prompt
  if (json_mode)               body$format <- "json"
  tryCatch({
    resp <- request(OLLAMA_URL) |>
      req_url_path("/api/generate") |>
      req_body_json(body) |>
      req_timeout(120) |>
      req_perform()
    resp_body_json(resp)$response
  }, error = function(e) paste("Ollama not reachable:", e$message))
}

TOOL_DESCRIPTIONS <- paste(
  "Available tools:\n",
  "1. count_variants_in_gene             — count variants in a gene | params: {gene}\n",
  "2. get_high_impact_variants_in_gene   — high-impact + CADD > threshold | params: {gene, cadd_min}\n",
  "3. count_sift_deleterious_in_gene     — SIFT deleterious in gene | params: {gene}\n",
  "4. get_high_impact_homozygous_ALS     — homozygous in ALS patients | params: {}\n",
  "5. get_top_deleterious_in_gene        — top N most deleterious | params: {gene, top_n}\n",
  "6. get_highest_af_variant             — highest allele frequency | params: {}\n",
  "7. get_average_af_by_impact           — average AF per impact category | params: {}\n",
  "8. get_total_burden_cases_vs_controls — total burden cases vs controls | params: {}\n",
  "9. summarize_variants_by_gene         — gene summary table | params: {min_variants, order_by}\n",
  "10. get_carriers_by_gene              — carriers in ALS/Control group | params: {gene, group}\n",
  "11. get_database_limitations          — what is NOT available | params: {}\n",
  "12. summarize_database                — database statistics | params: {}\n",
  "13. run_query                         — free SELECT query | params: {sql}\n",
  sep = ""
)

classify_question <- function(question, orch_model = "llama3.1:8b") {
  sys <- paste0(
    PROMPTS$data_description, "\n\n",
    PROMPTS$extra_instructions, "\n\n",
    "Output ONLY a valid JSON object with exactly two keys: 'tool' and 'params'.\n",
    "No explanation. No markdown. No extra text. No backticks.\n\n",
    TOOL_DESCRIPTIONS, "\n",
    "RULES:\n",
    "- Gene names always uppercase: NEK1, SOD1, TARDBP, FUS, ABCA4\n",
    "- 'Select variants' or 'show variants' = return rows, use get_high_impact_variants_in_gene\n",
    "- 'Count' or 'how many' = return a number, use count_variants_in_gene\n",
    "- NEVER use IS NOT NULL for CADDphred/PolyPhen/SIFT — use != '.' instead\n",
    "- For unanswerable questions (age, sex, ClinVar, population-AF): use get_database_limitations\n",
    "- For vague questions (most important): use get_database_limitations\n\n",
    "Return ONLY the JSON object for this question:\n", question
  )
  raw <- call_ollama(question, system_prompt = sys, model = orch_model, json_mode = TRUE)
  tryCatch({
    clean <- gsub("```json|```", "", raw)
    clean <- trimws(clean)
    start <- regexpr("\\{", clean)[[1]]
    end   <- tail(gregexpr("\\}", clean)[[1]], 1)
    if (start > 0 && end > start) clean <- substr(clean, start, end)
    parsed <- fromJSON(clean, simplifyVector = FALSE)
    if (is.null(parsed$tool)) stop("No 'tool' key found")
    list(ok = TRUE, tool = parsed$tool,
         params = if (is.null(parsed$params)) list() else parsed$params)
  }, error = function(e) {
    list(ok = FALSE, error = paste0("Classification failed: ", e$message, "\nModel: ", raw))
  })
}

summarize_result <- function(question, tool_name, result_json,
                             row_count = NULL, orch_model = "llama3.1:8b") {
  sys <- paste0(
    PROMPTS$data_description, "\n\n",
    "You are an ALS bioinformatics assistant. ",
    "Give a short, clear English summary (max 3 sentences). ",
    "Do not use SQL, JSON or technical jargon. ",
    "Start directly with the conclusion. ",
    "Always mention exact numbers when you know them. ",
    "IMPORTANT: Always respond in English only. Never use Dutch or any other language."
  )
  preview <- if (nchar(result_json) > 3000) {
    paste0(substr(result_json, 1, 3000), "\n... [result shortened]")
  } else result_json
  count_hint <- if (!is.null(row_count)) {
    paste0("\nThe exact number of rows found is: ", row_count, ". Always mention this.\n")
  } else ""
  prompt <- paste0(
    "[Respond in English only. Do not use Dutch.]\n\n",
    "User question: ", question, "\n",
    "Tool used: ", tool_name, "\n",
    count_hint,
    "Result:\n", preview, "\n\n",
    "Write a short 2-3 sentence answer in English. Start with the conclusion."
  )
  call_ollama(prompt, system_prompt = sys, model = orch_model)
}

check_mcp_error <- function(raw_result) {
  parsed <- tryCatch(fromJSON(raw_result, simplifyVector = FALSE), error = function(e) NULL)
  if (!is.null(parsed$error)) parsed$error else NULL
}

run_dual_pipeline <- function(question, orch_model, sub_model, progress_fn = NULL) {
  if (!is.null(progress_fn)) progress_fn("Orchestrator interpreting question...", 1)
  
  cl <- classify_question(question, orch_model = orch_model)
  if (!cl$ok) {
    cl <- classify_question(
      paste0(question, "\nRespond with ONLY a JSON object."),
      orch_model = orch_model
    )
  }
  if (!cl$ok) return(list(ok = FALSE, text = paste("Classification failed:", cl$error), tool = NULL, df = NULL))
  
  tool   <- cl$tool
  params <- if (is.null(cl$params)) list() else as.list(cl$params)
  
  if (tool == "run_query" && !is.null(params$sql)) {
    if (!is.null(progress_fn)) progress_fn("Subagent refining SQL...", 2)
    sub_sys <- paste0(
      PROMPTS$data_description, "\n\n",
      "You are a SQL specialist. Improve the SQL for SQLite on varInfo_synthetic.\n",
      "Rules: NEVER use IS NOT NULL — missing values are '.', use != '.' instead.\n",
      "Use CAST(CADDphred AS REAL) for numeric comparisons.\n",
      "Return ONLY the improved SQL. No explanation."
    )
    improved_sql <- call_ollama(
      paste0("Improve this SQL query:\n", params$sql),
      system_prompt = sub_sys, model = sub_model, num_predict = 300
    )
    improved_sql <- trimws(gsub("```sql|```", "", improved_sql))
    if (grepl("^SELECT", improved_sql, ignore.case = TRUE)) params$sql <- improved_sql
  }
  
  if (!is.null(progress_fn)) progress_fn("Executing query via MCP...", 3)
  raw_result <- call_mcp(tool, params)
  
  mcp_err <- check_mcp_error(raw_result)
  if (!is.null(mcp_err)) {
    return(list(ok = FALSE, text = paste("Database error:", mcp_err), tool = tool, df = NULL))
  }
  
  if (!is.null(progress_fn)) progress_fn("Formulating answer...", 4)
  df <- tryCatch({
    parsed <- fromJSON(raw_result, flatten = TRUE)
    if (is.data.frame(parsed)) parsed
    else if (is.list(parsed) && length(parsed) > 0) {
      flat <- unlist(parsed, recursive = TRUE)
      data.frame(key = names(flat), value = as.character(unname(flat)), stringsAsFactors = FALSE)
    } else data.frame(result = as.character(raw_result))
  }, error = function(e) data.frame(result = raw_result))
  
  summary_text <- summarize_result(question, tool, raw_result, nrow(df), orch_model = orch_model)
  list(ok = TRUE, text = summary_text, tool = tool, params = params, df = df)
}

run_single_pipeline <- function(question, model, progress_fn = NULL) {
  if (!is.null(progress_fn)) progress_fn("LLM interpreting and classifying...", 1)
  
  cl <- classify_question(question, orch_model = model)
  if (!cl$ok) {
    cl <- classify_question(
      paste0(question, "\nRespond with ONLY a JSON object."),
      orch_model = model
    )
  }
  if (!cl$ok) return(list(ok = FALSE, text = paste("Classification failed:", cl$error), tool = NULL, df = NULL))
  
  tool   <- cl$tool
  params <- if (is.null(cl$params)) list() else as.list(cl$params)
  
  if (tool == "run_query" && !is.null(params$sql)) {
    if (!grepl("^\\s*SELECT", params$sql, ignore.case = TRUE)) {
      return(list(ok = FALSE, text = "Only SELECT queries are permitted.", tool = tool, df = NULL))
    }
  }
  
  if (!is.null(progress_fn)) progress_fn("Executing query via MCP...", 2)
  raw_result <- call_mcp(tool, params)
  
  mcp_err <- check_mcp_error(raw_result)
  if (!is.null(mcp_err)) {
    return(list(ok = FALSE, text = paste("Database error:", mcp_err), tool = tool, df = NULL))
  }
  
  if (!is.null(progress_fn)) progress_fn("Formulating answer...", 3)
  df <- tryCatch({
    parsed <- fromJSON(raw_result, flatten = TRUE)
    if (is.data.frame(parsed)) parsed
    else if (is.list(parsed) && length(parsed) > 0) {
      flat <- unlist(parsed, recursive = TRUE)
      data.frame(key = names(flat), value = as.character(unname(flat)), stringsAsFactors = FALSE)
    } else data.frame(result = as.character(raw_result))
  }, error = function(e) data.frame(result = raw_result))
  
  summary_text <- summarize_result(question, tool, raw_result, nrow(df), orch_model = model)
  list(ok = TRUE, text = summary_text, tool = tool, params = params, df = df)
}

# ══════════════════════════════════════════════════════════════════════════════
# UI
# ══════════════════════════════════════════════════════════════════════════════

ui <- page_sidebar(
  title = "Project ALS — Variant Assistant",
  theme = bs_theme(
    version    = 5,
    bootswatch = "flatly",
    primary    = "#2A9D8F",
    secondary  = "#457B9D",
    "navbar-bg" = "#18bc9c"
  ),
  
  useShinyjs(),
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
      .shiny-progress .progress-bar { background-color: #2A9D8F !important; }
      .shiny-progress .progress { background-color: #e8f4f1 !important; }
      .shiny-progress-container { top: 60px !important; }
      .progress-bar { background-color: #2A9D8F !important; }
      .shiny-progress-indicator { background-color: #2A9D8F !important; }
      #shiny-notification-panel .progress-bar { background-color: #2A9D8F !important; }
      .navbar, .navbar-default, nav.navbar { background-color: #18bc9c !important; border-color: #18bc9c !important; }
      .bslib-page-sidebar > .navbar { background-color: #18bc9c !important; }
      #send_btn { background-color: #2A9D8F !important; border-color: #2A9D8F !important; color: white !important; }
      #send_btn:hover { background-color: #21867a !important; border-color: #21867a !important; }
      .input-disabled { opacity: 0.5; pointer-events: none; }
      .sidebar a { color: #2A9D8F !important; }
      .chat-bubble-unanswerable {
        background: #f8f9fa; border: 1px dashed #ced4da;
        padding: 10px 14px; border-radius: 18px 18px 18px 4px;
        margin: 6px 50px 6px 0; color: #6c757d;
      }
      .tool-detail {
        margin-top: 8px; padding: 8px 10px;
        background: #f8f9fa; border-radius: 6px;
        border-left: 3px solid #dee2e6;
        font-size: 0.8em; color: #555;
      }
      .tool-detail > summary {
        cursor: pointer; color: #888; font-size: 0.82em;
        user-select: none; list-style: none; outline: none;
      }
      .tool-detail > summary::-webkit-details-marker { display: none; }
      .tool-detail > summary::before { content: '\25B6  '; font-size: 0.75em; }
      .tool-detail[open] > summary::before { content: '\25BC  '; }
      .sql-block {
        margin-top: 6px; padding: 6px 8px;
        background: #1e1e2e; color: #cdd6f4;
        border-radius: 4px; font-family: monospace;
        font-size: 0.82em; white-space: pre-wrap; word-break: break-all;
      }
      .conf-high   { background:#ffeaea; color:#c0392b; border:1px solid #f5c6cb;
                     font-size:0.72em; padding:1px 7px; border-radius:10px; font-weight:600; }
      .conf-medium { background:#fff8e1; color:#856404; border:1px solid #ffeeba;
                     font-size:0.72em; padding:1px 7px; border-radius:10px; font-weight:600; }
      .conf-low    { background:#e8f4f1; color:#2A9D8F; border:1px solid #c3e6e0;
                     font-size:0.72em; padding:1px 7px; border-radius:10px; font-weight:600; }
      /* ── Session tracker ── */
      .tracker-row {
        display: flex; justify-content: space-between; align-items: center;
        padding: 5px 10px; border-radius: 6px; margin-bottom: 4px;
        border-left: 3px solid #2A9D8F; background: #f0f9f8;
      }
      .tracker-row.error-row { border-left-color: #E63946; background: #fef0f1; }
      .tracker-label { font-size: 0.78em; color: #666; }
      .tracker-value { font-size: 0.9em; font-weight: 600; color: #2A9D8F; }
      .tracker-value.error-value { color: #E63946; }
      /* ── Model switcher ── */
      .model-option {
        display: flex; align-items: flex-start; gap: 8px;
        padding: 8px 10px; border-radius: 8px; margin-bottom: 6px;
        border: 1px solid #dee2e6; cursor: pointer;
        transition: border-color 0.15s, background 0.15s;
        background: white;
      }
      .model-option:hover { border-color: #2A9D8F; background: #f0f9f8; }
      .model-option.selected { border-color: #2A9D8F; background: #f0f9f8; }
      .model-option input[type=radio] { margin-top: 3px; accent-color: #2A9D8F; flex-shrink: 0; }
      .model-option-body { display: flex; flex-direction: column; gap: 2px; }
      .model-option-label { font-size: 0.82em; font-weight: 600; color: #333; line-height: 1.3; }
      .model-option-desc  { font-size: 0.74em; color: #888; line-height: 1.3; }
      .model-mode-pill {
        display: inline-block; font-size: 0.68em; font-weight: 600;
        padding: 1px 6px; border-radius: 8px; margin-left: 4px;
        vertical-align: middle;
      }
      .pill-single { background: #e8f4f1; color: #2A9D8F; }
      .pill-dual   { background: #e8eef4; color: #457B9D; }
      /* ── Question history ── */
      .qhist-item {
        display: flex; align-items: center; gap: 6px;
        padding: 5px 8px; border-radius: 6px; margin-bottom: 3px;
        background: #f8f9fa; border: 1px solid #eee;
        cursor: pointer; transition: background 0.12s, border-color 0.12s;
      }
      .qhist-item:hover { background: #e8f4f1; border-color: #2A9D8F; }
      .qhist-num {
        font-size: 0.68em; font-weight: 700; color: #aaa;
        min-width: 16px; text-align: right; flex-shrink: 0;
      }
      .qhist-text {
        font-size: 0.76em; color: #444; white-space: nowrap;
        overflow: hidden; text-overflow: ellipsis; flex: 1;
      }
      .qhist-empty {
        font-size: 0.78em; color: #aaa; font-style: italic;
        padding: 4px 8px;
      }
      /* ── Export button ── */
      #export_btn {
        width: 100%;
        background: white !important;
        border: 1px solid #2A9D8F !important;
        color: #2A9D8F !important;
        font-size: 0.82em;
        padding: 4px 10px;
        border-radius: 6px;
      }
      #export_btn:hover {
        background: #e8f4f1 !important;
      }
      /* ── Export modal checkboxes ── */
      .export-option {
        display: flex; align-items: flex-start; gap: 8px;
        padding: 8px 10px; border-radius: 8px; margin-bottom: 6px;
        border: 1px solid #dee2e6; cursor: pointer;
        transition: border-color 0.15s, background 0.15s;
        background: white;
      }
      .export-option:hover { border-color: #2A9D8F; background: #f0f9f8; }
      .export-section-label {
        font-size: 0.78em; font-weight: 700; color: #888;
        text-transform: uppercase; letter-spacing: 0.04em;
        margin: 10px 0 5px 0;
      }
      /* ── Sidebar accordion sections ── */
      .sb-section {
        border: 1px solid #e4eeec; border-radius: 8px;
        margin-bottom: 6px; overflow: hidden;
      }
      .sb-section > summary {
        display: flex; align-items: center; justify-content: space-between;
        padding: 7px 11px; cursor: pointer;
        font-size: 0.82em; font-weight: 700; color: #444;
        background: #f0f9f8; user-select: none;
        list-style: none; outline: none;
        border-radius: 8px; transition: background 0.12s;
      }
      .sb-section > summary::-webkit-details-marker { display: none; }
      .sb-section > summary::after {
        content: '';
        display: inline-block;
        width: 0; height: 0;
        border-top: 5px solid transparent;
        border-bottom: 5px solid transparent;
        border-left: 6px solid #2A9D8F;
        transition: transform 0.15s;
        flex-shrink: 0;
      }
      .sb-section[open] > summary { border-radius: 8px 8px 0 0; background: #e4f5f2; }
      .sb-section[open] > summary::after { transform: rotate(90deg); }
      .sb-section > summary:hover { background: #e4f5f2; }
      .sb-section-body { padding: 10px 11px 10px 11px; }
    ")),
    tags$script(HTML(
      "$(document).on('keypress', '#user_input', function(e) {
         if (e.which == 13 && !e.shiftKey) { e.preventDefault(); $('#send_btn').click(); }
       });
       function selectModel(key) {
         document.querySelectorAll('.model-option').forEach(function(el) {
           el.classList.remove('selected');
         });
         var opt = document.getElementById('model-opt-' + key);
         if (opt) opt.classList.add('selected');
         Shiny.setInputValue('selected_model', key, {priority: 'event'});
       }
       // Populate input from question history click
       function historyClick(q) {
         var el = document.getElementById('user_input');
         if (el) {
           el.value = q;
           // trigger Shiny to see the new value
           el.dispatchEvent(new Event('input'));
         }
       }"
    ))
  ),
  
  sidebar = sidebar(
    width = 310,
    div(style = "margin-bottom:10px;",
        h4("Variant Assistant", style = "margin:0 0 2px 0;"),
        p("ALS variant database assistant.", style = "color:#888; font-size:0.8em; margin:0;")),
    
    # ── Pipeline ──────────────────────────────────────────────
    tags$details(
      class = "sb-section", open = NA,
      tags$summary("Pipeline"),
      div(class = "sb-section-body", uiOutput("model_switcher_ui"))
    ),
    
    # ── Example Questions ─────────────────────────────────────
    tags$details(
      class = "sb-section",
      tags$summary("Example Questions"),
      div(class = "sb-section-body",
          tags$ul(
            style = "padding-left:14px; margin:0;",
            tags$li(actionLink("ex1", "How many variants are in ABCA4?")),
            tags$li(actionLink("ex2", "How many variants in SOD1 are high impact?")),
            tags$li(actionLink("ex3", "How many genes are in the database?")),
            tags$li(actionLink("ex4", "How many total variants are in the database?")),
            tags$li(actionLink("ex5", "How many variants have PolyPhen predicted damaging?")),
            tags$li(actionLink("ex6", "Which gene has the fewest variants?")),
            tags$li(actionLink("ex7", "How many high-impact variants does ALS_3 carry?")),
            tags$li(actionLink("ex8", "What is the average age of ALS patients?"))
          ))
    ),
    
    # ── Question History ──────────────────────────────────────
    tags$details(
      class = "sb-section",
      tags$summary("Question History"),
      div(class = "sb-section-body", uiOutput("question_history_ui"))
    ),
    
    # ── Status ────────────────────────────────────────────────
    tags$details(
      class = "sb-section", open = NA,
      tags$summary("Status"),
      div(class = "sb-section-body", uiOutput("status_ui"))
    ),
    
    # ── Session tracker ───────────────────────────────────────
    tags$details(
      class = "sb-section", open = NA,
      tags$summary("Session"),
      div(class = "sb-section-body", uiOutput("session_tracker_ui"))
    ),
    
    # ── Export ────────────────────────────────────────────────
    div(style = "margin-top:8px;",
        actionButton("export_btn", "Export session", class = "btn btn-sm",
                     style = "width:100%;"))
  ),
  
  layout_columns(
    col_widths = c(5, 7),
    card(
      full_screen = TRUE,
      card_header(
        div(style = "display:flex; justify-content:space-between; align-items:center;",
            h4("Chat", style = "margin:0;"),
            div(style = "display:flex; align-items:center; gap:8px;",
                uiOutput("mode_badge_ui"),
                actionButton("clear_btn_header", "✕",
                             title = "Clear conversation",
                             class = "btn btn-sm",
                             style = "padding:1px 7px; font-size:0.8em; line-height:1.4;
                                      background:transparent; border:1px solid #dee2e6;
                                      color:#999; border-radius:12px;")))
      ),
      div(id = "chat_scroll", uiOutput("chat_ui")),
      uiOutput("progress_ui"),
      uiOutput("input_area_ui")
    ),
    card(
      full_screen = TRUE,
      card_header(
        div(style = "display:flex; justify-content:space-between; align-items:center;",
            uiOutput("results_title_ui"),
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
    messages            = list(),
    last_df             = NULL,
    is_loading          = FALSE,
    mcp_ok              = NA,
    row_count           = NULL,
    progress_log        = character(0),
    questions_asked     = 0L,
    tools_called        = 0L,
    errors_this_session = 0L,
    question_history    = character(0)   # NEW — ordered list of user questions
  )
  
  observe({
    tryCatch({
      resp <- request(MCP_URL) |> req_url_path("/openapi.json") |> req_timeout(4) |> req_perform()
      rv$mcp_ok <- resp_status(resp) == 200
    }, error = function(e) rv$mcp_ok <- FALSE)
  })
  
  current_pipeline <- reactive({
    key <- if (is.null(input$selected_model)) "dual_llama" else input$selected_model
    AVAILABLE_MODELS[[key]]
  })
  
  # ── Model switcher ──────────────────────────────────────────
  output$model_switcher_ui <- renderUI({
    selected <- if (is.null(input$selected_model)) "dual_llama" else input$selected_model
    opts <- lapply(names(AVAILABLE_MODELS), function(key) {
      m <- AVAILABLE_MODELS[[key]]
      pill_class <- if (m$mode == "dual") "model-mode-pill pill-dual" else "model-mode-pill pill-single"
      pill_text  <- if (m$mode == "dual") "two LLM" else "single"
      is_sel <- identical(key, selected)
      div(
        id    = paste0("model-opt-", key),
        class = if (is_sel) "model-option selected" else "model-option",
        onclick = paste0("selectModel('", key, "')"),
        tags$input(type = "radio", name = "model_radio", value = key,
                   checked = if (is_sel) NA else NULL),
        div(class = "model-option-body",
            div(class = "model-option-label",
                m$label,
                span(class = pill_class, pill_text)),
            div(class = "model-option-desc", m$desc))
      )
    })
    tagList(opts)
  })
  
  output$mode_badge_ui <- renderUI({
    p <- current_pipeline()
    if (p$mode == "dual") span("Two LLM", class = "mode-badge mode-dual")
    else                  span("Single LLM", class = "mode-badge mode-single")
  })
  
  output$status_ui <- renderUI({
    if (is.na(rv$mcp_ok)) {
      div(style = "color:#888;", "● Checking...")
    } else if (rv$mcp_ok) {
      div(style = "color:#2A9D8F; font-weight:bold;", "● MCP connected")
    } else {
      tagList(div(style = "color:red; font-weight:bold;", "● MCP unreachable"),
              tags$small("Restart start_services.sh"))
    }
  })
  
  output$session_tracker_ui <- renderUI({
    has_errors <- rv$errors_this_session > 0L
    div(
      div(class = "tracker-row",
          span(class = "tracker-label", "Questions asked"),
          span(class = "tracker-value", rv$questions_asked)),
      div(class = "tracker-row",
          span(class = "tracker-label", "Tools called"),
          span(class = "tracker-value", rv$tools_called)),
      div(class = if (has_errors) "tracker-row error-row" else "tracker-row",
          span(class = "tracker-label", "Errors"),
          span(class = if (has_errors) "tracker-value error-value" else "tracker-value",
               rv$errors_this_session))
    )
  })
  
  # ── Question history UI ─────────────────────────────────────
  output$question_history_ui <- renderUI({
    qs <- rv$question_history
    if (length(qs) == 0) {
      return(div(class = "qhist-empty", "No questions yet."))
    }
    # Show most recent first
    items <- lapply(rev(seq_along(qs)), function(i) {
      q     <- qs[[i]]
      label <- if (nchar(q) > 48) paste0(substr(q, 1, 45), "…") else q
      # onclick populates the input field (doesn't auto-submit)
      div(
        class   = "qhist-item",
        title   = q,
        onclick = paste0("historyClick(", jsonlite::toJSON(q, auto_unbox = TRUE), ")"),
        span(class = "qhist-num",  paste0("#", i)),
        span(class = "qhist-text", label)
      )
    })
    div(style = "max-height:180px; overflow-y:auto;", items)
  })
  
  output$row_count_ui <- renderUI({
    req(!is.null(rv$row_count))
    tags$small(style = "color:#666;", paste0(rv$row_count, " rows"))
  })
  
  output$results_title_ui <- renderUI({
    if (rv$is_loading) {
      div(style = "display:flex; align-items:center; gap:8px;",
          h4("Results", style = "margin:0;"),
          tags$span(style = "font-size:0.78em; color:#2A9D8F; font-weight:600;
                             background:#e8f4f1; padding:2px 8px; border-radius:10px;",
                    "⟳ Waiting for query..."))
    } else if (!is.null(rv$last_df)) {
      h4("Results", style = "margin:0;")
    } else {
      div(style = "display:flex; align-items:center; gap:8px;",
          h4("Results", style = "margin:0;"),
          tags$span(style = "font-size:0.78em; color:#aaa; padding:2px 4px;",
                    "Ask a question to see data"))
    }
  })
  
  # ── Clear ───────────────────────────────────────────────────
  observeEvent(input$clear_btn_header, {
    rv$messages             <- list()
    rv$last_df              <- NULL
    rv$row_count            <- NULL
    rv$progress_log         <- character(0)
    rv$questions_asked      <- 0L
    rv$tools_called         <- 0L
    rv$errors_this_session  <- 0L
    rv$question_history     <- character(0)
  })
  
  output$progress_ui <- renderUI({
    if (!rv$is_loading && length(rv$progress_log) == 0) return(NULL)
    steps <- rv$progress_log
    els <- lapply(seq_along(steps), function(i) {
      is_last <- i == length(steps)
      icon <- if (!is_last || !rv$is_loading) "✓" else "⟳"
      cls  <- if (!is_last || !rv$is_loading) "progress-step done" else "progress-step"
      div(class = cls, paste(icon, steps[i]))
    })
    div(style = "margin-top:6px; padding:8px 12px; background:#f0f9f8;
                 border-radius:6px; border-left:4px solid #2A9D8F;", els)
  })
  
  # ── Example question links ───────────────────────────────────
  ex_map <- list(
    ex1 = "How many variants are in ABCA4?",
    ex2 = "How many variants in SOD1 are high impact?",
    ex3 = "How many genes are in the database?",
    ex4 = "How many total variants are in the database?",
    ex5 = "How many variants have PolyPhen predicted damaging?",
    ex6 = "Which gene has the fewest variants?",
    ex7 = "How many high-impact variants does ALS_3 carry?",
    ex8 = "What is the average age of ALS patients?"
  )
  for (id in names(ex_map)) {
    local({
      q <- ex_map[[id]]
      observeEvent(input[[id]], updateTextInput(session, "user_input", value = q))
    })
  }
  
  output$input_area_ui <- renderUI({
    div(style = "display:flex; gap:8px; margin-top:10px;",
        textInput("user_input", label = NULL, width = "100%",
                  placeholder = "Ask a question... (Enter to send)"),
        actionButton("send_btn", "→", class = "btn-primary"))
  })
  
  observe({
    if (rv$is_loading) {
      shinyjs::disable("user_input")
      shinyjs::disable("send_btn")
      shinyjs::addCssClass("user_input", "input-disabled")
    } else {
      shinyjs::enable("user_input")
      shinyjs::enable("send_btn")
      shinyjs::removeCssClass("user_input", "input-disabled")
    }
  })
  
  # ── Send handler ─────────────────────────────────────────────
  handle_send <- function() {
    question <- trimws(input$user_input)
    req(nchar(question) > 0, !rv$is_loading)
    updateTextInput(session, "user_input", value = "")
    
    # Append to history (avoid exact consecutive duplicate)
    prev <- rv$question_history
    if (length(prev) == 0 || tail(prev, 1) != question) {
      rv$question_history <- c(prev, question)
    }
    
    rv$messages     <- c(rv$messages, list(list(role = "user", text = question)))
    rv$is_loading   <- TRUE
    rv$row_count    <- NULL
    rv$progress_log <- character(0)
    shinyjs::delay(100, {
      p <- isolate(current_pipeline())
      total_steps <- if (p$mode == "dual") 4 else 3
      result <- withProgress(message = "Processing your question...", value = 0, {
        update_progress <- function(msg, step) {
          rv$progress_log <- c(rv$progress_log, msg)
          setProgress(value = step / total_steps, message = msg)
        }
        tryCatch({
          if (p$mode == "dual") run_dual_pipeline(question, p$orch, p$sub, update_progress)
          else                  run_single_pipeline(question, p$orch, update_progress)
        }, error = function(e) list(ok = FALSE, text = paste("Error:", e$message), tool = NULL, df = NULL))
      })
      
      rv$questions_asked <- rv$questions_asked + 1L
      
      if (result$ok) {
        rv$last_df      <- result$df
        rv$row_count    <- if (!is.null(result$df)) nrow(result$df) else NULL
        rv$tools_called <- rv$tools_called + 1L
      } else {
        rv$errors_this_session <- rv$errors_this_session + 1L
      }
      
      rv$messages <- c(rv$messages, list(list(
        role = "assistant", text = result$text, tool = result$tool,
        params = result$params, mode = p$mode
      )))
      rv$is_loading <- FALSE
    })
  }
  
  observeEvent(input$send_btn, handle_send())
  
  # ── Chat UI ──────────────────────────────────────────────────
  output$chat_ui <- renderUI({
    msgs <- rv$messages
    if (length(msgs) == 0) {
      return(p(style = "color:#999; font-style:italic; text-align:center; margin-top:40px;",
               "Ask a question about the ALS variant database..."))
    }
    
    tool_confidence <- function(tool) {
      if (is.null(tool)) return(NULL)
      if (tool == "run_query")
        return(tags$span(class = "conf-high", "⚠ free SQL — verify"))
      if (tool == "get_database_limitations")
        return(tags$span(class = "conf-medium", "✘ unanswerable"))
      return(tags$span(class = "conf-low", "✔ named tool"))
    }
    
    tool_detail_panel <- function(tool, params) {
      if (is.null(tool)) return(NULL)
      param_lines <- if (!is.null(params) && length(params) > 0) {
        paste(names(params), unlist(params), sep = " = ", collapse = "\n")
      } else "(no params)"
      sql_block <- if (!is.null(params$sql)) {
        div(class = "sql-block", params$sql)
      } else NULL
      tags$details(
        class = "tool-detail",
        tags$summary("tool details"),
        div(style = "margin-top:5px;",
            tags$b("Tool: "), tags$code(tool), tags$br(),
            if (!is.null(params$sql)) NULL else
              tagList(tags$b("Params: "),
                      tags$code(style = "font-size:0.9em;", param_lines)),
            sql_block)
      )
    }
    
    els <- lapply(msgs, function(m) {
      if (m$role == "user") {
        div(class = "chat-bubble-user", m$text)
      } else {
        is_unanswerable <- identical(m$tool, "get_database_limitations")
        bubble_class    <- if (is_unanswerable) "chat-bubble-unanswerable" else "chat-bubble-bot"
        
        mode_label <- if (!is.null(m$mode) && m$mode == "dual")
          tags$small(class = "tool-badge", "two-llm pipeline") else NULL
        
        header_row <- if (!is.null(m$tool)) {
          div(style = "display:flex; align-items:center; gap:6px; margin-bottom:4px;",
              tags$small(class = "tool-badge", style = "margin:0;",
                         paste0("tool: ", m$tool)),
              tool_confidence(m$tool))
        } else NULL
        
        rendered <- HTML(gsub("\\*\\*(.*?)\\*\\*", "<strong>\\1</strong>",
                              gsub("\n", "<br>", m$text)))
        
        detail <- tool_detail_panel(m$tool, m$params)
        
        div(class = bubble_class, mode_label, header_row, rendered, detail)
      }
    })
    
    loading_bubble <- if (rv$is_loading) {
      list(
        div(class = "chat-bubble-bot",
            style = "background:#f0f9f8; border-color:#c8e6e3;",
            div(style = "display:flex; align-items:center; gap:10px; padding:4px 0;",
                tags$span(style = "width:14px; height:14px; border-radius:50%; background:#E63946;
                                   display:inline-block; animation:mine-bounce 1.2s infinite ease-in-out;
                                   animation-delay:0s;"),
                tags$span(style = "width:14px; height:14px; border-radius:50%; background:#2A9D8F;
                                   display:inline-block; animation:mine-bounce 1.2s infinite ease-in-out;
                                   animation-delay:0.2s;"),
                tags$span(style = "width:14px; height:14px; border-radius:50%; background:#E76F51;
                                   display:inline-block; animation:mine-bounce 1.2s infinite ease-in-out;
                                   animation-delay:0.4s;"),
                tags$span(style = "color:#2A9D8F; font-size:0.85em; font-weight:600; margin-left:2px;",
                          "Working...")))
      )
    } else NULL
    
    tags$div(els, loading_bubble,
             tags$script(HTML("
               (function() {
                 var el = document.getElementById('chat_scroll');
                 if (!el) return;
                 el.scrollTop = el.scrollHeight;
                 if (!el._obs) {
                   el._obs = new MutationObserver(function() {
                     el.scrollTop = el.scrollHeight;
                   });
                   el._obs.observe(el, { childList: true, subtree: true });
                 }
               })();
             ")))
  })
  
  output$result_table <- renderDT({
    req(!is.null(rv$last_df))
    datatable(rv$last_df,
              options = list(pageLength = 15, scrollX = TRUE, dom = "frtip",
                             language = list(search = "Search:",
                                             info = "Showing _START_ to _END_ of _TOTAL_ rows",
                                             paginate = list(previous = "Previous", `next` = "Next"))),
              rownames = FALSE, class = "table-sm table-striped table-hover")
  })
  
  # ════════════════════════════════════════════════════════════
  # EXPORT — modal with format + content options
  # ════════════════════════════════════════════════════════════
  
  observeEvent(input$export_btn, {
    has_table <- !is.null(rv$last_df)
    showModal(modalDialog(
      title = "Export Session",
      size  = "s",
      easyClose = TRUE,
      footer = tagList(
        modalButton("Cancel"),
        downloadButton("do_export", "Download", class = "btn btn-primary btn-sm")
      ),
      
      # Format section
      div(class = "export-section-label", "Format"),
      radioButtons("export_format", label = NULL,
                   choices = c(
                     "Plain text (.txt)"  = "txt",
                     "CSV (.csv)"         = "csv",
                     "HTML report (.html)" = "html"
                   ),
                   selected = "txt"),
      
      # Content section
      div(class = "export-section-label", "Include"),
      checkboxGroupInput("export_content", label = NULL,
                         choices = c(
                           "Chat log"      = "chat",
                           "Results table" = "table"
                         ),
                         selected = c("chat", if (has_table) "table")),
      
      if (!has_table)
        tags$small(style = "color:#aaa;",
                   "No results table available yet in this session.")
    ))
  })
  
  # ── Build export content ────────────────────────────────────
  
  build_chat_txt <- function() {
    msgs <- rv$messages
    if (length(msgs) == 0) return("(no conversation)")
    lines <- vapply(msgs, function(m) {
      role <- if (m$role == "user") "You" else "Assistant"
      tool_info <- if (!is.null(m$tool)) paste0(" [tool: ", m$tool, "]") else ""
      paste0("[", role, tool_info, "]\n", m$text)
    }, character(1))
    paste(lines, collapse = "\n\n---\n\n")
  }
  
  build_table_txt <- function() {
    df <- rv$last_df
    if (is.null(df)) return("(no results table)")
    paste(capture.output(print(df, row.names = FALSE)), collapse = "\n")
  }
  
  build_chat_html <- function() {
    msgs <- rv$messages
    if (length(msgs) == 0) return("<p><em>No conversation.</em></p>")
    parts <- lapply(msgs, function(m) {
      if (m$role == "user") {
        paste0('<div style="text-align:right;margin:6px 0;">',
               '<span style="background:#2A9D8F;color:white;padding:6px 12px;',
               'border-radius:14px;display:inline-block;">',
               htmltools::htmlEscape(m$text), '</span></div>')
      } else {
        tool_line <- if (!is.null(m$tool))
          paste0('<div style="font-size:0.78em;color:#888;margin-bottom:4px;">tool: ',
                 htmltools::htmlEscape(m$tool), '</div>') else ""
        txt <- gsub("\n", "<br>", htmltools::htmlEscape(m$text))
        txt <- gsub("\\*\\*(.*?)\\*\\*", "<strong>\\1</strong>", txt)
        paste0('<div style="background:#f8f9fa;border:1px solid #dee2e6;',
               'padding:10px 14px;border-radius:14px;margin:6px 0;">',
               tool_line, txt, '</div>')
      }
    })
    paste(parts, collapse = "\n")
  }
  
  build_table_html <- function() {
    df <- rv$last_df
    if (is.null(df)) return("<p><em>No results table.</em></p>")
    header <- paste0("<th style='padding:4px 10px;border:1px solid #dee2e6;background:#f0f9f8;'>",
                     names(df), "</th>", collapse = "")
    rows <- apply(df, 1, function(row) {
      cells <- paste0("<td style='padding:4px 10px;border:1px solid #dee2e6;'>",
                      htmltools::htmlEscape(as.character(row)), "</td>", collapse = "")
      paste0("<tr>", cells, "</tr>")
    })
    paste0('<table style="border-collapse:collapse;font-size:0.85em;width:100%;">',
           "<thead><tr>", header, "</tr></thead><tbody>",
           paste(rows, collapse = ""), "</tbody></table>")
  }
  
  output$do_export <- downloadHandler(
    filename = function() {
      fmt  <- input$export_format %||% "txt"
      stamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
      paste0("als_session_", stamp, ".", fmt)
    },
    content = function(file) {
      fmt     <- input$export_format %||% "txt"
      content <- input$export_content %||% "chat"
      want_chat  <- "chat"  %in% content
      want_table <- "table" %in% content
      
      if (fmt == "csv") {
        # CSV: table rows if selected; chat as extra rows appended
        rows <- list()
        if (want_table && !is.null(rv$last_df)) {
          rows[["table"]] <- rv$last_df
        }
        if (want_chat) {
          chat_df <- do.call(rbind, lapply(rv$messages, function(m) {
            data.frame(
              role       = m$role,
              text       = m$text,
              tool       = if (!is.null(m$tool)) m$tool else "",
              stringsAsFactors = FALSE
            )
          }))
          rows[["chat"]] <- chat_df
        }
        # Write tables separated by blank line
        con <- file(file, open = "w")
        for (nm in names(rows)) {
          writeLines(paste0("# ", nm), con)
          write.csv(rows[[nm]], con, row.names = FALSE)
          writeLines("", con)
        }
        close(con)
        
      } else if (fmt == "html") {
        chat_block  <- if (want_chat)  build_chat_html()  else ""
        table_block <- if (want_table) build_table_html() else ""
        ts <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
        html <- paste0(
          '<!DOCTYPE html><html><head><meta charset="UTF-8">',
          '<title>ALS Variant Assistant — Session Export</title>',
          '<style>body{font-family:sans-serif;max-width:860px;margin:40px auto;color:#333;}',
          'h1{color:#2A9D8F;}h2{color:#457B9D;margin-top:30px;}',
          '.ts{color:#aaa;font-size:0.8em;}</style></head><body>',
          '<h1>Project ALS — Variant Assistant</h1>',
          '<p class="ts">Exported: ', ts, '</p>',
          if (want_chat)  paste0('<h2>Chat Log</h2>',    chat_block),
          if (want_table) paste0('<h2>Results Table</h2>', table_block),
          '</body></html>'
        )
        writeLines(html, file)
        
      } else {
        # Plain text (default)
        sections <- character(0)
        ts <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
        sections <- c(sections,
                      paste0("Project ALS — Variant Assistant\nSession export: ", ts, "\n",
                             strrep("=", 50)))
        if (want_chat) {
          sections <- c(sections,
                        paste0("CHAT LOG\n", strrep("-", 40), "\n", build_chat_txt()))
        }
        if (want_table) {
          sections <- c(sections,
                        paste0("RESULTS TABLE\n", strrep("-", 40), "\n", build_table_txt()))
        }
        writeLines(paste(sections, collapse = "\n\n"), file)
      }
    }
  )
}

shinyApp(ui, server)
