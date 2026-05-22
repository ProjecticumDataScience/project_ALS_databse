## ============================================================
## backends/backend_dual.R
## Two-LLM pipeline:
##   Orchestrator (qwen3:8b) — understands the question,
##     resolves ambiguity, catches unanswerable questions,
##     and summarises the final answer for the user.
##   Subagent (llama3.1:8b) — receives a structured intent
##     from the orchestrator, calls the database tool, and
##     returns raw results.
##
## Flow per question:
##   1. Orchestrator interprets user question → structured intent
##   2. Subagent calls query_variants tool → raw result
##   3. Orchestrator summarises result → final user-facing answer
##
## Mirrors the standard adapter interface:
##   dual_setup()             → session object
##   dual_ask(session, q)     → list(response, full)
## ============================================================

library(ellmer)
library(DBI)
library(jsonlite)
library(R.utils)

dual_setup <- function(model_name, gdb, data_description, extra_instructions,
                       orchestrator_model, subagent_model) {
  
  ## Test both models are reachable
  for (m in c(orchestrator_model, subagent_model)) {
    ok <- tryCatch({
      chat_ollama(model = m,
                  params = ellmer::params(temperature = 0.1, num_predict = 10),
                  api_args = list(timeout = 60))
      TRUE
    }, error = function(e) {
      cat("ERROR: Could not load model", m, "-", e$message, "\n")
      FALSE
    })
    if (!ok) return(NULL)
  }
  
  cat("  Dual backend: orchestrator =", orchestrator_model,
      "| subagent =", subagent_model, "\n")
  
  list(
    model_name         = model_name,          ## used for CSV grouping
    orchestrator_model = orchestrator_model,
    subagent_model     = subagent_model,
    gdb                = gdb,
    data_description   = data_description,
    extra_instructions = extra_instructions
  )
}

dual_ask <- function(session, question) {
  tryCatch({
    withTimeout({
      
      log_parts <- list()
      
      ## ── Orchestrator system prompt ────────────────────────
      ## Focused entirely on language and intent — no SQL knowledge needed.
      orchestrator_system <- paste0(
        session$data_description, "\n\n",
        session$extra_instructions, "\n\n",
        "You are the ORCHESTRATOR in a two-model pipeline.\n",
        "Your job in this step is to analyse the user's question and produce\n",
        "a single clear, precise instruction for a SQL subagent.\n\n",
        "Rules:\n",
        "- If the question asks for something NOT available in the database columns,\n",
        "  respond with exactly: UNANSWERABLE: <reason>\n",
        "  Examples of unanswerable: age, ethnicity, ClinVar pathogenicity,\n",
        "  population-stratified frequencies, anything not in the schema.\n",
        "- If the question is ambiguous (e.g. 'most important'), clarify which\n",
        "  metric you will use and include that decision in your instruction.\n",
        "- Otherwise, write a precise one-sentence instruction for the subagent,\n",
        "  e.g. 'Count the number of variants in varInfo_synthetic where gene_name\n",
        "  = NEK1 and HighImpact = 1 and CAST(CADDphred AS REAL) > 20.'\n",
        "- Do NOT write SQL yourself. Do NOT call any tools.\n",
        "- Respond with only the instruction or UNANSWERABLE line. Nothing else."
      )
      
      ## ── Step 1: Orchestrator interprets the question ──────
      orchestrator <- chat_ollama(
        model         = session$orchestrator_model,
        system_prompt = orchestrator_system,
        params        = ellmer::params(temperature = 0.1, num_predict = 200),
        api_args      = list(timeout = 300)
      )
      
      intent <- orchestrator$chat(question, echo = "none")
      log_parts$intent <- intent
      cat("    [orchestrator intent]:", substr(intent, 1, 120), "\n")
      
      ## ── Check if orchestrator refused ─────────────────────
      if (grepl("^UNANSWERABLE:", intent, ignore.case = TRUE)) {
        reason <- trimws(sub("^UNANSWERABLE:\\s*", "", intent, ignore.case = TRUE))
        
        full_log <- paste0(
          "[orchestrator] UNANSWERABLE\n",
          "Reason: ", reason, "\n"
        )
        
        return(list(response = reason, full = full_log))
      }
      
      ## ── Tool definition for subagent ──────────────────────
      tool_log <- list(sql = NULL, raw_result = NULL, error = NULL)
      
      query_fun <- function(sql) {
        if (!grepl("^\\s*SELECT", sql, ignore.case = TRUE)) {
          tool_log$error <<- "Only SELECT queries are allowed."
          return("Error: only SELECT queries are allowed.")
        }
        tool_log$sql <<- sql
        result <- tryCatch({
          dbGetQuery(session$gdb, sql)
        }, error = function(e) {
          tool_log$error <<- e$message
          return(NULL)
        })
        if (is.null(result)) {
          msg <- paste("Query error:", tool_log$error)
          tool_log$raw_result <<- msg
          return(msg)
        }
        if (nrow(result) > 200) result <- result[1:200, ]
        json_out <- toJSON(result, auto_unbox = TRUE)
        tool_log$raw_result <<- as.character(json_out)
        return(as.character(json_out))
      }
      
      query_tool <- tool(
        query_fun,
        description = paste0(
          "Run a SELECT query on the varInfo_synthetic ALS variant database. ",
          "Returns JSON. Max 200 rows. ",
          "Columns: VAR_id, CHROM, POS, ID, REF, ALT, AC, AN, AF, ",
          "gene_name, HighImpact, ModerateImpact, Synonymous, ",
          "CADDphred, PolyPhen, SIFT, ",
          "ALS_1..ALS_5 (ALS patient genotypes 0/1/2), ",
          "Control_1..Control_5 (control genotypes 0/1/2). ",
          "Missing values stored as '.' not NULL — filter with != '.'"
        ),
        name      = "query_variants",
        arguments = list(
          sql = type_string("A valid SQLite SELECT statement querying varInfo_synthetic.")
        )
      )
      
      ## ── Subagent system prompt ────────────────────────────
      ## Focused entirely on SQL and tool execution.
      subagent_system <- paste0(
        "You are a SQL subagent. You will receive a precise instruction from an orchestrator.\n",
        "Your ONLY job is to call the query_variants tool with the correct SQL to fulfil\n",
        "that instruction. Do not explain. Do not summarise. Just call the tool.\n\n",
        "Database table: varInfo_synthetic\n",
        "Columns: VAR_id, CHROM, POS, ID, REF, ALT, AC, AN, AF, ",
        "gene_name, HighImpact (0/1), ModerateImpact (0/1), Synonymous (0/1), ",
        "CADDphred (TEXT, missing='.'), PolyPhen (TEXT, missing='.'), SIFT (TEXT, missing='.'), ",
        "ALS_1..ALS_5 (INTEGER 0/1/2), Control_1..Control_5 (INTEGER 0/1/2).\n\n",
        "Rules:\n",
        "- Always filter missing values with != '.' before using CADDphred/PolyPhen/SIFT.\n",
        "- Use CAST(CADDphred AS REAL) for numeric comparisons.\n",
        "- For burden: SUM(ALS_1+ALS_2+ALS_3+ALS_4+ALS_5).\n",
        "- For homozygous: column = 2.\n",
        "- Call the tool exactly once. Return nothing else."
      )
      
      ## ── Step 2: Subagent executes the tool ───────────────
      subagent <- chat_ollama(
        model         = session$subagent_model,
        system_prompt = subagent_system,
        params        = ellmer::params(temperature = 0.0, num_predict = 400),
        api_args      = list(timeout = 300)
      )
      subagent$register_tool(query_tool)
      subagent$chat(intent, echo = "none")
      
      raw_result <- tool_log$raw_result %||% "No tool was called."
      sql_used   <- tool_log$sql        %||% "No SQL generated."
      cat("    [subagent sql]:", substr(sql_used, 1, 120), "\n")
      
      ## ── Step 3: Orchestrator summarises for the user ─────
      summary_prompt <- paste0(
        "Original user question: ", question, "\n\n",
        "Database result:\n", substr(raw_result, 1, 2000), "\n\n",
        "Give a direct, concise answer in 1-3 sentences. ",
        "Start with the answer. No SQL, no JSON, no jargon."
      )
      
      final_answer <- orchestrator$chat(summary_prompt, echo = "none")
      cat("    [orchestrator final]:", substr(final_answer, 1, 120), "\n")
      
      ## ── Build full log ────────────────────────────────────
      full_log <- paste0(
        "[orchestrator] intent: ", intent, "\n",
        "[subagent tool=query_variants] sql: ", sql_used, "\n",
        "[subagent result (first 1000 chars)]\n",
        substr(raw_result, 1, 1000), "\n",
        "[orchestrator final]\n",
        final_answer
      )
      
      list(response = final_answer, full = full_log)
      
    }, timeout = 600, onTimeout = "error")   ## longer timeout — 3 LLM calls
    
  }, error = function(e) {
    msg <- paste("TIMEOUT/ERROR:", e$message)
    list(response = msg, full = msg)
  })
}

`%||%` <- function(a, b) if (!is.null(a)) a else b
