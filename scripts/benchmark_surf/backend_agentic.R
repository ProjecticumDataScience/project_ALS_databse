## ============================================================
## backend_agentic.R
## Agentic pipeline backend for the benchmark.
## Wraps run_pipeline() from app2.R logic into the standard
## setup_session / ask_question interface.
##
## Supports two modes:
##   BACKEND = "agentic_single"  →  single LLM + agentic routing
##   BACKEND = "agentic_dual"    →  dual LLM + agentic routing
## ============================================================

library(httr2)
library(jsonlite)

## ── Source agentic pipeline logic ────────────────────────────
## pipeline.R contains all logic (no Shiny UI) — source directly
pipeline_script <- file.path(
  path.expand("~/project_ALS_databse/scripts/agentic_surf"),
  "pipeline.R"
)
stopifnot(file.exists(pipeline_script))
source(pipeline_script)
cat("Agentic pipeline loaded from:", pipeline_script, "\n")

## ── Model warmup ── pre-loads ORCH_MODEL and DECOMPOSE_MODEL into Ollama
## memory ONCE before any benchmark question runs. Prevents the cold-start
## timeouts that occur when the first question forces a model switch.
cat("\n========== WARMUP ==========\n")
warmup_result <- warmup_all_models()
if (!warmup_result$ok) {
  cat("WARNING: warmup had failures — first few benchmark questions may be slow/unreliable\n")
}
cat("=============================\n\n")

## ── Session setup ────────────────────────────────────────────

agentic_setup <- function(model_name) {
  ## model_name formats:
  ##   "llama3.1:8b"                    (single)
  ##   "llama3.1:8b -> duckdb-nsql"     (dual)
  ##   "llama3.1:8b [adaptive]"         (adaptive)
  
  if (grepl("\\[adaptive\\]", model_name)) {
    orch_model <- trimws(gsub("\\s*\\[adaptive\\]", "", model_name))
    sub_model  <- NULL
    mode       <- "dual_adaptive"
  } else if (grepl("->", model_name)) {
    parts      <- strsplit(model_name, "\\s*->\\s*")[[1]]
    orch_model <- trimws(parts[1])
    sub_model  <- trimws(parts[2])
    mode       <- "dual"
  } else {
    orch_model <- model_name
    sub_model  <- NULL
    mode       <- "single"
  }
  
  ## Check Ollama is reachable
  ok <- tryCatch({
    resp <- request(OLLAMA_URL) |>
      req_url_path("/api/tags") |>
      req_timeout(5) |>
      req_perform()
    resp_status(resp) == 200
  }, error = function(e) FALSE)
  
  if (!ok) {
    cat("WARNING: Ollama not reachable at", OLLAMA_URL, "\n")
    return(NULL)
  }
  
  ## Check MCP is reachable
  mcp_ok <- tryCatch({
    resp <- request(MCP_BASE) |>
      req_url_path("/db_exploration/openapi.json") |>
      req_timeout(5) |>
      req_perform()
    resp_status(resp) == 200
  }, error = function(e) FALSE)
  
  if (!mcp_ok) {
    cat("WARNING: MCP not reachable at", MCP_BASE, "\n")
    return(NULL)
  }
  
  ## For adaptive mode, load SUB_SQL_MODEL and SUB_REASON_MODEL from config
  sub_sql    <- if (mode == "dual_adaptive" && exists("SUB_SQL_MODEL"))    SUB_SQL_MODEL    else NULL
  sub_reason <- if (mode == "dual_adaptive" && exists("SUB_REASON_MODEL")) SUB_REASON_MODEL else NULL
  
  list(
    mode       = mode,
    orch       = orch_model,
    sub        = sub_model,
    sub_sql    = sub_sql,
    sub_reason = sub_reason,
    mcp_base   = MCP_BASE,
    ollama_url = OLLAMA_URL
  )
}

## ── Ask question ─────────────────────────────────────────────

agentic_ask <- function(session, question) {
  p <- list(mode = session$mode, orch = session$orch, sub = session$sub)
  
  ## Capture cat() output for the full log
  log_lines <- character(0)
  result <- tryCatch({
    withCallingHandlers(
      run_pipeline(question, p, progress_fn = NULL),
      message = function(m) {
        log_lines <<- c(log_lines, conditionMessage(m))
        invokeRestart("muffleMessage")
      }
    )
  }, error = function(e) {
    list(ok = FALSE, text = paste("Pipeline error:", e$message),
         tool = NULL, df = NULL, mode = session$mode)
  })
  
  ## Build full log for benchmark output
  tool_str   <- result$tool %||% "unknown"
  mode_str   <- result$mode %||% session$mode
  steps_str  <- if (!is.null(result$steps_log) && length(result$steps_log) > 0) {
    paste(result$steps_log, collapse = " → ")
  } else tool_str
  
  complexity_str <- result$complexity %||% "unknown"
  full <- paste0(
    "[mode: ", mode_str, "]\n",
    "[complexity: ", complexity_str, "]\n",
    "[tools called: ", steps_str, "]\n",
    "--- Final response ---\n",
    result$text %||% "(no response)"
  )
  
  list(
    full     = full,
    response = result$text %||% "(no response)",
    phase_timing = result$phase_timing
  )
}