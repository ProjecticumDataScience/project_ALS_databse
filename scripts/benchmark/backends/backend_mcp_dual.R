## ============================================================
## backends/backend_mcp_dual.R
## Two-LLM pipeline over MCP:
##
##   Orchestrator (language specialist)
##     - understands the question
##     - resolves ambiguity
##     - catches unanswerable questions
##     - produces a plain English intent (NOT SQL)
##     - summarises the final result for the user
##
##   Subagent (SQL specialist e.g. duckdb-nsql, sqlcoder)
##     - receives the plain English intent
##     - generates correct SQL
##     - SQL is executed via mcpo HTTP → SQLite
##
## model_name format: "orch_model -> sub_model"
## e.g. "mistral -> duckdb-nsql"
## ============================================================

library(httr2)
library(jsonlite)
library(R.utils)

## ── Internal: call mcpo tool via HTTP ────────────────────────
.mcp_call <- function(tool_name, body = list(), mcp_url) {
  tryCatch({
    resp <- request(mcp_url) |>
      req_url_path(paste0("/", tool_name)) |>
      req_body_json(body) |>
      req_timeout(30) |>
      req_perform()
    resp_body_string(resp)
  }, error = function(e) {
    toJSON(list(error = e$message), auto_unbox = TRUE)
  })
}

## ── Internal: call Ollama generate endpoint ───────────────────
.ollama_call <- function(prompt, system_prompt = NULL,
                         model, ollama_url,
                         temperature = 0.1, num_predict = 400) {
  body <- list(
    model   = model,
    prompt  = prompt,
    stream  = FALSE,
    options = list(temperature = temperature, num_predict = num_predict)
  )
  if (!is.null(system_prompt)) body$system <- system_prompt
  
  tryCatch({
    resp <- request(ollama_url) |>
      req_url_path("/api/generate") |>
      req_body_json(body) |>
      req_timeout(300) |>
      req_perform()
    resp_body_json(resp)$response
  }, error = function(e) {
    paste("Ollama error:", e$message)
  })
}

## ── Public interface ──────────────────────────────────────────

mcp_dual_setup <- function(model_name, mcp_url, ollama_url,
                           data_description, extra_instructions) {
  
  ## Parse "orch -> sub" label
  parts <- strsplit(model_name, " -> ", fixed = TRUE)[[1]]
  if (length(parts) != 2) {
    cat("ERROR: mcp_dual model_name must be 'orch -> sub', got:", model_name, "\n")
    return(NULL)
  }
  orchestrator_model <- trimws(parts[1])
  subagent_model     <- trimws(parts[2])
  
  ## Check mcpo is reachable
  reachable <- tryCatch({
    resp <- request(mcp_url) |>
      req_url_path("/openapi.json") |>
      req_timeout(5) |>
      req_perform()
    resp_status(resp) == 200
  }, error = function(e) FALSE)
  
  if (!reachable) {
    cat("ERROR: MCP server not reachable at", mcp_url,
        "- is your bash launcher running?\n")
    return(NULL)
  }
  
  ## Fetch schema once for the subagent
  schema_info <- tryCatch({
    raw  <- .mcp_call("describe_table",
                      body    = list(table_name = "varInfo_synthetic"),
                      mcp_url = mcp_url)
    cols <- fromJSON(raw)
    if (is.data.frame(cols) && "name" %in% names(cols)) {
      paste(apply(cols, 1, function(r) paste0(r["name"], " (", r["type"], ")")),
            collapse = ", ")
    } else stop("unexpected schema response")
  }, error = function(e) {
    paste(
      "VAR_id, CHROM, POS, ID, REF, ALT, AC, AN, AF,",
      "gene_name, HighImpact (0/1), ModerateImpact (0/1), Synonymous (0/1),",
      "CADDphred (TEXT missing='.'), PolyPhen (TEXT missing='.'),",
      "SIFT (TEXT missing='.'),",
      "ALS_1..ALS_5 (INTEGER 0/1/2), Control_1..Control_5 (INTEGER 0/1/2)"
    )
  })
  
  cat("  MCP dual: orchestrator =", orchestrator_model,
      "| subagent =", subagent_model, "\n")
  
  list(
    model_name         = model_name,
    orchestrator_model = orchestrator_model,
    subagent_model     = subagent_model,
    mcp_url            = mcp_url,
    ollama_url         = ollama_url,
    schema_info        = schema_info,
    data_description   = data_description,
    extra_instructions = extra_instructions
  )
}

mcp_dual_ask <- function(session, question) {
  tryCatch({
    withTimeout({
      
      ## ── Orchestrator system prompt ────────────────────────
      ## Language only — never writes SQL
      orch_system <- paste0(
        session$data_description, "\n\n",
        session$extra_instructions, "\n\n",
        "You are a language specialist in a genomics pipeline. ",
        "A SQL expert will handle all database queries — your job is language only.\n\n",
        "When given a question, reply with ONE of these three options:\n\n",
        "Option A — a single plain-English sentence describing what to query.\n",
        "  Use column names but NEVER write SQL syntax, operators, or SELECT statements.\n",
        "  Good examples:\n",
        "  'Count the number of variants where gene_name equals NEK1'\n",
        "  'Sum ALS_1 plus ALS_2 plus ALS_3 plus ALS_4 plus ALS_5 as case_burden,",
        " and sum Control_1 through Control_5 as control_burden'\n",
        "  'Calculate the average of AF separately for rows where HighImpact equals 1,",
        " where ModerateImpact equals 1, and where Synonymous equals 1'\n\n",
        "Option B — UNANSWERABLE: followed by the reason.\n",
        "  Use only when the data needed is not in the database",
        " (age, ethnicity, ClinVar, population-specific frequencies).\n\n",
        "Option C — AMBIGUOUS: followed by what needs clarifying.\n",
        "  Use only when the question is too vague to query",
        " (e.g. most important, best).\n\n",
        "Critical rules:\n",
        "- Do NOT write SQL. Do NOT use SELECT, WHERE, FROM, SUM(), AVG(), or any SQL.\n",
        "- Do NOT number your response or use headers.\n",
        "- Respond with one sentence only.\n",
        "- Burden comparisons between cases and controls ARE answerable."
      )
      
      ## ── Subagent system prompt ────────────────────────────
      ## SQL only — receives plain English, outputs one SELECT statement
      sub_system <- paste0(
        "You are a SQL specialist subagent. You receive a plain-English instruction\n",
        "and must output ONE valid SQLite SELECT statement. Nothing else.\n",
        "No explanation. No markdown. Just the raw SQL.\n\n",
        "Database table: varInfo_synthetic\n",
        "Columns: ", session$schema_info, "\n\n",
        "SQL rules:\n",
        "- Only add CADDphred != '.' when the instruction specifically involves CADD\n",
        "- For simple counts or gene filters: no CADDphred filter\n",
        "- Numeric CADD comparison: CAST(CADDphred AS REAL) > 20\n",
        "- Burden: SUM(ALS_1+ALS_2+ALS_3+ALS_4+ALS_5)\n",
        "- Homozygous: column = 2\n",
        "- Carrier: column > 0\n",
        "- Separate categories: use CASE WHEN or run grouped query\n",
        "- Output ONLY the SELECT statement, nothing else"
      )
      
      ## ── STEP 1: Orchestrator produces plain English intent ─
      intent <- .ollama_call(
        prompt        = paste0("Question: ", question),
        system_prompt = orch_system,
        model         = session$orchestrator_model,
        ollama_url    = session$ollama_url,
        temperature   = 0.1,
        num_predict   = 200
      )
      intent <- trimws(intent)
      cat("    [orchestrator intent]:", substr(intent, 1, 120), "\n")
      
      ## Strip ALL CALL N / CALL N: lines anywhere in the response
      intent <- gsub("CALL\\s*[12]\\s*:?[^\\n]*\\n?", "", intent, perl = TRUE)
      intent <- trimws(intent)
      
      ## If orchestrator still wrote SQL, use it directly — skip subagent LLM call
      intent_is_sql <- grepl("^SELECT", trimws(intent), ignore.case = TRUE)
      if (intent_is_sql) {
        cat("    [note: orchestrator produced SQL — passing through to mcpo]\n")
      }
      
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
      
      ## ── STEP 2: Subagent generates SQL from intent ────────
      ## If orchestrator already produced SQL, skip the subagent LLM call
      if (intent_is_sql) {
        sql <- intent
        cat("    [subagent sql (passthrough)]:", substr(sql, 1, 120), "\n")
      } else {
        sql_raw <- .ollama_call(
          prompt        = paste0("Instruction: ", intent),
          system_prompt = sub_system,
          model         = session$subagent_model,
          ollama_url    = session$ollama_url,
          temperature   = 0.0,
          num_predict   = 300
        )
        sql <- gsub("```sql|```", "", sql_raw)
        sql <- trimws(sql)
        cat("    [subagent sql]:", substr(sql, 1, 120), "\n")
      }
      
      ## Guard: must be a SELECT
      if (!grepl("^SELECT", sql, ignore.case = TRUE)) {
        msg <- paste0("Subagent did not produce valid SQL: ", sql)
        return(list(response = msg, full = msg))
      }
      
      ## ── STEP 3: Execute SQL via mcpo ──────────────────────
      raw_result <- .mcp_call(
        "query_variants",
        body    = list(sql = sql),
        mcp_url = session$mcp_url
      )
      cat("    [mcpo result (first 100 chars)]:",
          substr(raw_result, 1, 100), "\n")
      
      ## ── STEP 4: Orchestrator summarises ───────────────────
      summary_prompt <- paste0(
        "Original user question: ", question, "\n\n",
        "Database result:\n", substr(raw_result, 1, 2000), "\n\n",
        "Summarise in 1-3 sentences. Start with the answer. ",
        "No SQL, no JSON, no jargon."
      )
      
      final_answer <- .ollama_call(
        prompt        = summary_prompt,
        system_prompt = orch_system,
        model         = session$orchestrator_model,
        ollama_url    = session$ollama_url,
        temperature   = 0.1,
        num_predict   = 300
      )
      cat("    [orchestrator summary]:", substr(final_answer, 1, 120), "\n")
      
      full_log <- paste0(
        "[orchestrator intent]\n", intent, "\n\n",
        "[subagent sql]\n", sql, "\n\n",
        "[mcpo result (first 1000 chars)]\n", substr(raw_result, 1, 1000), "\n\n",
        "[orchestrator summary]\n", final_answer
      )
      
      list(response = final_answer, full = full_log)
      
    }, timeout = 600, onTimeout = "error")
    
  }, error = function(e) {
    msg <- paste("TIMEOUT/ERROR:", e$message)
    list(response = msg, full = msg)
  })
}
