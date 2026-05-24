## ============================================================
## backends/backend_ellmer.R
## Adapter that runs one benchmark question via raw ellmer
## tool-calling — no querychat layer at all.
## Compatible with ellmer 0.4.0
## ============================================================

library(ellmer)
library(DBI)
library(jsonlite)
library(R.utils)

ellmer_setup <- function(model_name, gdb, data_description, extra_instructions) {
  client_test <- tryCatch({
    chat_ollama(
      model    = model_name,
      params   = ellmer::params(temperature = 0.1, num_predict = 400),
      api_args = list(timeout = 300)
    )
  }, error = function(e) {
    cat("ERROR: Could not load model", model_name, "-", e$message, "\n")
    return(NULL)
  })
  
  if (is.null(client_test)) return(NULL)
  
  list(
    model_name         = model_name,
    gdb                = gdb,
    data_description   = data_description,
    extra_instructions = extra_instructions
  )
}

ellmer_ask <- function(session, question) {
  tryCatch({
    withTimeout({
      
      tool_log <- list(sql = NULL, raw_result = NULL, error = NULL)
      
      ## ── Tool using correct ellmer 0.4.0 tool() signature ──
      ## First positional arg is the function, then named args
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
          err_msg <- paste("Query error:", tool_log$error)
          tool_log$raw_result <<- err_msg
          return(err_msg)
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
          "Use for any question answerable with SQL. ",
          "Columns: VAR_id, CHROM, POS, ID, REF, ALT, AC, AN, AF, ",
          "gene_name, HighImpact, ModerateImpact, Synonymous, ",
          "CADDphred, PolyPhen, SIFT, ",
          "ALS_1..ALS_5 (ALS patient genotypes 0/1/2), ",
          "Control_1..Control_5 (control genotypes 0/1/2). ",
          "Missing values for CADDphred/PolyPhen/SIFT stored as '.' not NULL."
        ),
        name      = "query_variants",
        arguments = list(
          sql = ellmer::type_string("A valid SQLite SELECT statement querying varInfo_synthetic.")
        )
      )
      
      ## ── System prompt ─────────────────────────────────────
      system_prompt <- paste0(
        session$data_description, "\n\n",
        session$extra_instructions, "\n\n",
        "You have access to one tool: query_variants(sql). ",
        "Use it to answer questions that require data from the database. ",
        "For questions that cannot be answered from the available columns, ",
        "do NOT call the tool — just explain that the information is not available. ",
        "After receiving the tool result, give a direct 1-3 sentence answer. ",
        "Do not call the tool more than once."
      )
      
      ## ── Fresh client ──────────────────────────────────────
      client <- chat_ollama(
        model    = session$model_name,
        system   = system_prompt,
        params   = ellmer::params(temperature = 0.1, num_predict = 400),
        api_args = list(timeout = 300)
      )
      client$register_tool(query_tool)
      
      response_text <- client$chat(question, echo = "none")
      
      full_log <- if (!is.null(tool_log$sql)) {
        paste0(
          "[tool=query_variants]\n",
          "SQL: ", tool_log$sql, "\n",
          "--- raw result (first 2000 chars) ---\n",
          substr(tool_log$raw_result %||% "", 1, 2000), "\n",
          "--- final response ---\n",
          response_text
        )
      } else {
        paste0(
          "[no tool call — model answered directly or refused]\n",
          "--- final response ---\n",
          response_text
        )
      }
      
      list(response = response_text, full = full_log)
      
    }, timeout = 300, onTimeout = "error")
    
  }, error = function(e) {
    msg <- paste("TIMEOUT/ERROR:", e$message)
    list(response = msg, full = msg)
  })
}

`%||%` <- function(a, b) if (!is.null(a)) a else b
