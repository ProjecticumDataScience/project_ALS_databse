## ============================================================
## backends/backend_dual.R
## Two-LLM pipeline — three steps, no validation/retry:
##   1. Orchestrator interprets question → structured intent
##   2. Subagent executes SQL tool → raw result
##   3. Orchestrator summarises result → final answer
##
## The subagent is trusted to do its job. The orchestrator stays
## in its lane: language understanding and final summary only.
##
## model_name format: "orch_model -> sub_model"
## e.g. "mistral -> llama3.1:8b"
## ============================================================

library(ellmer)
library(DBI)
library(jsonlite)
library(R.utils)

dual_setup <- function(model_name, gdb, data_description, extra_instructions,
                       orchestrator_model = NULL, subagent_model = NULL) {
  
  ## Parse "orch -> sub" label
  if (is.null(orchestrator_model) || is.null(subagent_model)) {
    parts <- strsplit(model_name, " -> ", fixed = TRUE)[[1]]
    if (length(parts) != 2) {
      cat("ERROR: dual model_name must be 'orch -> sub', got:", model_name, "\n")
      return(NULL)
    }
    orchestrator_model <- trimws(parts[1])
    subagent_model     <- trimws(parts[2])
  }
  
  for (m in c(orchestrator_model, subagent_model)) {
    ok <- tryCatch({
      chat_ollama(model    = m,
                  params   = ellmer::params(temperature = 0.1, num_predict = 10),
                  api_args = list(timeout = 60))
      TRUE
    }, error = function(e) {
      cat("ERROR: Could not load model", m, "-", e$message, "\n")
      FALSE
    })
    if (!ok) return(NULL)
  }
  
  cat("  Dual: orchestrator =", orchestrator_model,
      "| subagent =", subagent_model, "\n")
  
  list(
    model_name         = model_name,
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
      
      ## ── Orchestrator system prompt ────────────────────────
      orchestrator_system <- paste0(
        session$data_description, "\n\n",
        session$extra_instructions, "\n\n",
        "You are the ORCHESTRATOR in a two-model pipeline.\n\n",
        "Your role has two parts — you will be called twice:\n\n",
        
        "CALL 1 — INTENT:\n",
        "Analyse the user question and produce one precise instruction\n",
        "for a SQL subagent. Rules:\n",
        "- If unanswerable (age, ethnicity, ClinVar pathogenicity,\n",
        "  population-stratified frequencies, anything not in the schema):\n",
        "  respond with exactly: UNANSWERABLE: <reason>\n",
        "- If ambiguous ('most important', 'best', etc.):\n",
        "  respond with exactly: AMBIGUOUS: <what clarification is needed>\n",
        "- Always spell out exact column names. Never say 'cases' without\n",
        "  specifying ALS_1+ALS_2+ALS_3+ALS_4+ALS_5. Never say 'controls'\n",
        "  without specifying Control_1+Control_2+Control_3+Control_4+Control_5.\n",
        "- Burden comparisons (cases vs controls) ARE answerable — use\n",
        "  SUM or COUNT of the ALS/Control columns.\n",
        "- If separate results per category are needed, say 'grouped by category'.\n",
        "- Do NOT write SQL. Do NOT call tools. One instruction only.\n\n",
        
        "CALL 2 — SUMMARY:\n",
        "You will receive the database result. Summarise it for the user\n",
        "in 1-3 sentences. Start with the answer. No SQL, no JSON, no jargon.\n",
        "Trust the result — do not second-guess it."
      )
      
      ## ── Subagent system prompt ────────────────────────────
      subagent_system <- paste0(
        "You are a SQL subagent. You receive a precise instruction and must\n",
        "call the query_variants tool with correct SQL. Do not explain.\n\n",
        "Database: varInfo_synthetic\n",
        "Columns: VAR_id, CHROM, POS, ID, REF, ALT, AC, AN, AF, ",
        "gene_name, HighImpact (0/1), ModerateImpact (0/1), Synonymous (0/1), ",
        "CADDphred (TEXT), PolyPhen (TEXT), SIFT (TEXT), ",
        "ALS_1..ALS_5 (INTEGER 0/1/2), Control_1..Control_5 (INTEGER 0/1/2).\n\n",
        "SQL rules:\n",
        "- Only add CADDphred != '.' if the question specifically involves CADDphred.\n",
        "- For simple counts (e.g. how many variants in gene X): no CADDphred filter.\n",
        "- Numeric CADD comparison: CAST(CADDphred AS REAL) > 20\n",
        "- Burden: SUM(ALS_1+ALS_2+ALS_3+ALS_4+ALS_5)\n",
        "- Homozygous: column = 2\n",
        "- Separate categories: GROUP BY or CASE WHEN\n",
        "- Call the tool exactly once."
      )
      
      ## ── Tool definition ───────────────────────────────────
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
          "gene_name, HighImpact (0/1), ModerateImpact (0/1), Synonymous (0/1), ",
          "CADDphred (TEXT, missing='.'), PolyPhen (TEXT, missing='.'), ",
          "SIFT (TEXT, missing='.'), ",
          "ALS_1..ALS_5 (INTEGER 0/1/2), Control_1..Control_5 (INTEGER 0/1/2). ",
          "Only filter CADDphred != '.' when the question requires CADD scores."
        ),
        name      = "query_variants",
        arguments = list(
          sql = ellmer::type_string(
            "A valid SQLite SELECT statement querying varInfo_synthetic."
          )
        )
      )
      
      ## ── STEP 1: Orchestrator interprets ───────────────────
      orchestrator <- chat_ollama(
        model         = session$orchestrator_model,
        system_prompt = orchestrator_system,
        params        = ellmer::params(temperature = 0.1, num_predict = 300),
        api_args      = list(timeout = 300)
      )
      
      intent <- orchestrator$chat(
        paste0("Question: ", question), echo = "none"
      )
      cat("    [orchestrator intent]:", substr(intent, 1, 120), "\n")
      
      ## Stop if unanswerable or ambiguous
      if (grepl("^UNANSWERABLE:", intent, ignore.case = TRUE)) {
        reason <- trimws(sub("^UNANSWERABLE:\\s*", "", intent, ignore.case = TRUE))
        return(list(
          response = reason,
          full     = paste0("[orchestrator] UNANSWERABLE\nReason: ", reason, "\n")
        ))
      }
      
      if (grepl("^AMBIGUOUS:", intent, ignore.case = TRUE)) {
        clarification <- trimws(sub("^AMBIGUOUS:\\s*", "", intent, ignore.case = TRUE))
        return(list(
          response = paste0("This question is ambiguous — ", clarification),
          full     = paste0("[orchestrator] AMBIGUOUS\n", clarification, "\n")
        ))
      }
      
      ## ── STEP 2: Subagent executes ─────────────────────────
      subagent <- chat_ollama(
        model         = session$subagent_model,
        system_prompt = subagent_system,
        params        = ellmer::params(temperature = 0.0, num_predict = 400),
        api_args      = list(timeout = 300)
      )
      subagent$register_tool(query_tool)
      subagent$chat(intent, echo = "none")
      
      sql_used   <- tool_log$sql        %||% "No SQL generated."
      raw_result <- tool_log$raw_result %||% "No tool was called."
      cat("    [subagent sql]:", substr(sql_used, 1, 120), "\n")
      
      ## ── STEP 3: Orchestrator summarises ───────────────────
      summary_prompt <- paste0(
        "Original user question: ", question, "\n\n",
        "Database result:\n", substr(raw_result, 1, 2000), "\n\n",
        "Summarise in 1-3 sentences. Start with the answer. ",
        "No SQL, no JSON, no jargon. Trust the result."
      )
      
      final_answer <- orchestrator$chat(summary_prompt, echo = "none")
      cat("    [orchestrator final]:", substr(final_answer, 1, 120), "\n")
      
      full_log <- paste0(
        "[orchestrator intent]\n", intent, "\n\n",
        "[subagent sql]\n", sql_used, "\n\n",
        "[subagent result (first 1000 chars)]\n", substr(raw_result, 1, 1000), "\n\n",
        "[orchestrator final]\n", final_answer
      )
      
      list(response = final_answer, full = full_log)
      
    }, timeout = 600, onTimeout = "error")
    
  }, error = function(e) {
    msg <- paste("TIMEOUT/ERROR:", e$message)
    list(response = msg, full = msg)
  })
}

`%||%` <- function(a, b) if (!is.null(a)) a else b
