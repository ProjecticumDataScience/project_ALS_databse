# ─────────────────────────────────────────────────────────────────────────────
# Project ALS  —  Variant Assistant v2 (Agentic) [SURF — 70b]
# Shiny UI + Server — sources pipeline.R for all logic
# ─────────────────────────────────────────────────────────────────────────────

library(shiny)
library(bslib)
library(DT)
library(httr2)
library(jsonlite)
library(shinyjs)

## Source pipeline logic (config, LLM calls, tool routing, pipelines)
source(file.path(getwd(), "pipeline.R"))

# ══════════════════════════════════════════════════════════════════════════════
# UI
# ══════════════════════════════════════════════════════════════════════════════

ui <- page_sidebar(
  title = "Project ALS \u2014 Variant Assistant v2 (Agentic) [SURF \u2014 70b]",
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
      .tracker-row {
        display: flex; justify-content: space-between; align-items: center;
        padding: 5px 10px; border-radius: 6px; margin-bottom: 4px;
        border-left: 3px solid #2A9D8F; background: #f0f9f8;
      }
      .tracker-row.error-row { border-left-color: #E63946; background: #fef0f1; }
      .tracker-label { font-size: 0.78em; color: #666; }
      .tracker-value { font-size: 0.9em; font-weight: 600; color: #2A9D8F; }
      .tracker-value.error-value { color: #E63946; }
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
      #export_btn {
        width: 100%;
        background: white !important;
        border: 1px solid #2A9D8F !important;
        color: #2A9D8F !important;
        font-size: 0.82em;
        padding: 4px 10px;
        border-radius: 6px;
      }
      #export_btn:hover { background: #e8f4f1 !important; }
      .export-option {
        display: flex; align-items: flex-start; gap: 8px;
        padding: 8px 10px; border-radius: 8px; margin-bottom: 6px;
        border: 1px solid #dee2e6; cursor: pointer;
        transition: border-color 0.15s, background 0.15s;
        background: white;
      }
      .export-option:hover { border-color: #2A9D8F; background: #f0f9f8; }
      @keyframes mine-bounce {
        0%, 100% { transform: scale(1);   opacity: 1; }
        50%       { transform: scale(0.4); opacity: 0.4; }
      }
      .export-section-label {
        font-size: 0.78em; font-weight: 700; color: #888;
        text-transform: uppercase; letter-spacing: 0.04em;
        margin: 10px 0 5px 0;
      }
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
       function historyClick(q) {
         var el = document.getElementById('user_input');
         if (el) {
           el.value = q;
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
    
    tags$details(
      class = "sb-section", open = NA,
      tags$summary("Pipeline"),
      div(class = "sb-section-body",
          div(style = "font-weight:600; margin-bottom:2px;", "llama3.1:70b — adaptive pipeline"),
          p("Decomposes complex questions, picks the right database tool, ",
            "writes and validates SQL, and self-corrects on errors — all with one model.",
            style = "color:#888; font-size:0.8em; margin:0;"))
    ),
    
    tags$details(
      class = "sb-section",
      tags$summary("Example Questions"),
      div(class = "sb-section-body", uiOutput("example_questions_ui"))
    ),
    
    tags$details(
      class = "sb-section",
      tags$summary("Question History"),
      div(class = "sb-section-body", uiOutput("question_history_ui"))
    ),
    
    tags$details(
      class = "sb-section", open = NA,
      tags$summary("Status"),
      div(class = "sb-section-body", uiOutput("status_ui"))
    ),
    
    tags$details(
      class = "sb-section", open = NA,
      tags$summary("Session"),
      div(class = "sb-section-body", uiOutput("session_tracker_ui"))
    ),
    
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
                actionButton("clear_btn_header", "\u2715",
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
    warmup_status       = "pending",   ## "pending" | "warming" | "ready" | "failed"
    row_count           = NULL,
    progress_log        = character(0),
    questions_asked     = 0L,
    tools_called        = 0L,
    errors_this_session = 0L,
    question_history    = character(0)
  )
  
  observe({
    tryCatch({
      resp <- request(MCP_BASE) |> req_url_path("/openapi.json") |> req_timeout(4) |> req_perform()
      rv$mcp_ok <- resp_status(resp) == 200
    }, error = function(e) rv$mcp_ok <- FALSE)
  })

  ## ── Model warmup ── runs once when the app starts, before any question
  ## is processed. Pre-loads ORCH_MODEL and DECOMPOSE_MODEL into Ollama
  ## memory so the first real question doesn't pay the cold-start cost.
  observeEvent(TRUE, once = TRUE, {
    rv$warmup_status <- "warming"
    shinyjs::delay(50, {
      result <- warmup_all_models(status_fn = function(msg) {
        cat("[WARMUP UI]", msg, "\n")
      })
      rv$warmup_status <- if (result$ok) "ready" else "failed"
    })
  })
  
  ## Only one pipeline config now — see AVAILABLE_MODELS in pipeline.R for why
  ## the earlier single/dual/adaptive model picker was removed.
  current_pipeline <- reactive({
    AVAILABLE_MODELS$default
  })
  
  output$status_ui <- renderUI({
    mcp_line <- if (is.na(rv$mcp_ok)) {
      div(style = "color:#888;", "\u25cf Checking...")
    } else if (rv$mcp_ok) {
      div(style = "color:#2A9D8F; font-weight:bold;", "\u25cf MCP connected")
    } else {
      tagList(div(style = "color:red; font-weight:bold;", "\u25cf MCP unreachable"),
              tags$small("Restart start_services.sh"))
    }

    warmup_line <- switch(rv$warmup_status,
      "pending" = div(style = "color:#888;", "\u25cf Models not warmed up"),
      "warming" = div(style = "color:#E9A23B; font-weight:bold;", "\u27f3 Warming up models..."),
      "ready"   = div(style = "color:#2A9D8F; font-weight:bold;", "\u25cf Warmup completed"),
      "failed"  = tagList(div(style = "color:red; font-weight:bold;", "\u25cf Warmup failed"),
                          tags$small("Models may respond slowly to first question")),
      div(style = "color:#888;", "")
    )

    tagList(mcp_line, warmup_line)
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
  
  output$question_history_ui <- renderUI({
    qs <- rv$question_history
    if (length(qs) == 0) {
      return(div(class = "qhist-empty", "No questions yet."))
    }
    items <- lapply(rev(seq_along(qs)), function(i) {
      q     <- qs[[i]]
      label <- if (nchar(q) > 48) paste0(substr(q, 1, 45), "\u2026") else q
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
                    "\u27f3 Waiting for query..."))
    } else if (!is.null(rv$last_df)) {
      h4("Results", style = "margin:0;")
    } else {
      div(style = "display:flex; align-items:center; gap:8px;",
          h4("Results", style = "margin:0;"),
          tags$span(style = "font-size:0.78em; color:#aaa; padding:2px 4px;",
                    "Ask a question to see data"))
    }
  })
  
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
      icon <- if (!is_last || !rv$is_loading) "\u2713" else "\u27f3"
      cls  <- if (!is_last || !rv$is_loading) "progress-step done" else "progress-step"
      div(class = cls, paste(icon, steps[i]))
    })
    div(style = "margin-top:6px; padding:8px 12px; background:#f0f9f8;
                 border-radius:6px; border-left:4px solid #2A9D8F;", els)
  })
  
  ## Example questions are sourced from REASONING_EXAMPLES in pipeline.R —
  ## the same patterns the model has been shown, so user phrasing aligns
  ## with what the system actually handles well.
  ##
  ## Uses the same historyClick() JS function as Question History (direct
  ## DOM update) rather than a server round-trip via updateTextInput —
  ## the server round-trip could silently lose the update if input_area_ui
  ## happened to re-render between the click and the update arriving.
  output$example_questions_ui <- renderUI({
    tags$ul(
      style = "padding-left:14px; margin:0;",
      lapply(EXAMPLE_QUESTIONS_FOR_UI, function(q) {
        tags$li(
          tags$a(
            href = "#",
            onclick = paste0("historyClick(", jsonlite::toJSON(q, auto_unbox = TRUE), "); return false;"),
            q
          )
        )
      })
    )
  })
  
  output$input_area_ui <- renderUI({
    div(style = "display:flex; gap:8px; margin-top:10px;",
        textInput("user_input", label = NULL, width = "100%",
                  placeholder = "Ask a question... (Enter to send)"),
        actionButton("send_btn", "\u2192", class = "btn-primary"))
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
  
  handle_send <- function() {
    question <- trimws(input$user_input)
    req(nchar(question) > 0, !rv$is_loading)
    updateTextInput(session, "user_input", value = "")
    
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
      total_steps <- 6
      result <- withProgress(message = "Processing your question...", value = 0, {
        update_progress <- function(msg, step) {
          rv$progress_log <- c(rv$progress_log, msg)
          setProgress(value = step / total_steps, message = msg)
        }
        tryCatch({
          run_pipeline(question, p, update_progress)
        }, error = function(e) list(ok = FALSE, text = paste("Error:", e$message), tool = NULL, df = NULL))
      })
      
      rv$questions_asked <- rv$questions_asked + 1L
      
      if (result$ok) {
        ## get_database_limitations returns the full reference doc of what's
        ## NOT in the database (missing data, impossible combinations, etc.)
        ## as a flattened key/value table. That's correct data, but showing
        ## it as the main results table is noise — the chat bubble's
        ## one-sentence summary already answers the actual question, and
        ## dumping 7 unrelated rows of database limitations underneath it
        ## reads as a rendering bug rather than useful output.
        is_limitations_dump <- identical(result$tool, "db_exploration/get_database_limitations") ||
                                identical(result$tool, "get_database_limitations")
        if (is_limitations_dump) {
          rv$last_df   <- NULL
          rv$row_count <- NULL
        } else {
          rv$last_df      <- result$df
          rv$row_count    <- if (!is.null(result$df)) nrow(result$df) else NULL
        }
        rv$tools_called <- rv$tools_called + 1L
      } else {
        rv$errors_this_session <- rv$errors_this_session + 1L
      }
      
      rv$messages <- c(rv$messages, list(list(
        role = "assistant", text = result$text, tool = result$tool,
        params = result$params
      )))
      rv$is_loading <- FALSE
    })
  }
  
  observeEvent(input$send_btn, handle_send())
  
  output$chat_ui <- renderUI({
    msgs <- rv$messages
    if (length(msgs) == 0) {
      return(p(style = "color:#999; font-style:italic; text-align:center; margin-top:40px;",
               "Ask a question about the ALS variant database..."))
    }
    
    tool_confidence <- function(tool) {
      if (is.null(tool)) return(NULL)
      if (tool == "run_query")
        return(tags$span(class = "conf-high", "\u26a0 free SQL \u2014 verify"))
      if (tool == "get_database_limitations")
        return(tags$span(class = "conf-medium", "\u2718 unanswerable"))
      return(tags$span(class = "conf-low", "\u2714 named tool"))
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
        is_unanswerable_msg <- identical(m$tool, "get_database_limitations")
        bubble_class        <- if (is_unanswerable_msg) "chat-bubble-unanswerable" else "chat-bubble-bot"
        
        header_row <- if (!is.null(m$tool)) {
          div(style = "display:flex; align-items:center; gap:6px; margin-bottom:4px;",
              tags$small(class = "tool-badge", style = "margin:0;",
                         paste0("tool: ", m$tool)),
              tool_confidence(m$tool))
        } else NULL
        
        rendered <- HTML(gsub("\\*\\*(.*?)\\*\\*", "<strong>\\1</strong>",
                              gsub("\n", "<br>", m$text)))
        
        detail <- tool_detail_panel(m$tool, m$params)
        
        div(class = bubble_class, header_row, rendered, detail)
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
  
  # ── Export ───────────────────────────────────────────────────────────────────
  
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
      div(class = "export-section-label", "Format"),
      radioButtons("export_format", label = NULL,
                   choices = c(
                     "Plain text (.txt)"   = "txt",
                     "CSV (.csv)"          = "csv",
                     "HTML report (.html)" = "html"
                   ),
                   selected = "txt"),
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
      fmt   <- input$export_format %||% "txt"
      stamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
      paste0("als_session_", stamp, ".", fmt)
    },
    content = function(file) {
      fmt        <- input$export_format %||% "txt"
      content    <- input$export_content %||% "chat"
      want_chat  <- "chat"  %in% content
      want_table <- "table" %in% content
      
      if (fmt == "csv") {
        rows <- list()
        if (want_table && !is.null(rv$last_df)) rows[["table"]] <- rv$last_df
        if (want_chat) {
          chat_df <- do.call(rbind, lapply(rv$messages, function(m) {
            data.frame(
              role = m$role,
              text = m$text,
              tool = if (!is.null(m$tool)) m$tool else "",
              stringsAsFactors = FALSE
            )
          }))
          rows[["chat"]] <- chat_df
        }
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
          '<title>ALS Variant Assistant \u2014 Session Export</title>',
          '<style>body{font-family:sans-serif;max-width:860px;margin:40px auto;color:#333;}',
          'h1{color:#2A9D8F;}h2{color:#457B9D;margin-top:30px;}',
          '.ts{color:#aaa;font-size:0.8em;}</style></head><body>',
          '<h1>Project ALS \u2014 Variant Assistant</h1>',
          '<p class="ts">Exported: ', ts, '</p>',
          if (want_chat)  paste0('<h2>Chat Log</h2>',     chat_block),
          if (want_table) paste0('<h2>Results Table</h2>', table_block),
          '</body></html>'
        )
        writeLines(html, file)
        
      } else {
        sections <- character(0)
        ts <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
        sections <- c(sections,
                      paste0("Project ALS \u2014 Variant Assistant\nSession export: ", ts, "\n",
                             strrep("=", 50)))
        if (want_chat)  sections <- c(sections,
                                      paste0("CHAT LOG\n", strrep("-", 40), "\n", build_chat_txt()))
        if (want_table) sections <- c(sections,
                                      paste0("RESULTS TABLE\n", strrep("-", 40), "\n", build_table_txt()))
        writeLines(paste(sections, collapse = "\n\n"), file)
      }
    }
  )
}

shinyApp(ui, server)