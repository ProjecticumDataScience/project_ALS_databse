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
      client$register_tool(make_pheno_tool(session$gdb))
      client$register_tool(make_sex_distribution_tool(session$gdb))
      
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

## ── Additional rvat-aware tools ──────────────────────────────
## These are registered alongside query_variants in ellmer_setup.
## They handle questions requiring pheno/SM table joins.

make_pheno_tool <- function(gdb_obj) {
  pheno_fun <- function(sql) {
    ## Only allow SELECT on pheno, SM, or varInfo_synthetic
    if (!grepl("^\\s*SELECT", sql, ignore.case = TRUE)) {
      return("Error: only SELECT queries are allowed.")
    }
    result <- tryCatch({
      dbGetQuery(gdb_obj, sql)
    }, error = function(e) {
      return(data.frame(error = e$message))
    })
    if (nrow(result) > 200) result <- result[1:200, ]
    as.character(toJSON(result, auto_unbox = TRUE))
  }
  
  tool(
    pheno_fun,
    description = paste0(
      "Run a SELECT query joining varInfo_synthetic with pheno or SM tables. ",
      "Use for questions about sex, age, population, or cohort of carriers. ",
      "pheno columns: IID, sex (1=female 2=male), pheno (1=ALS 2=control), ",
      "pop, superPop, PC1-PC4, age. ",
      "SM columns: IID, sex. ",
      "IID values (ALS1, ALS2..Control1..) map to varInfo_synthetic genotype columns ",
      "by removing the underscore: ALS_1 column = IID 'ALS1'. ",
      "Example join for female ALS carriers of high-impact SOD1 variants: ",
      "SELECT p.IID, p.sex, p.pop FROM pheno p ",
      "WHERE p.sex = 1 AND p.IID IN ('ALS1','ALS2','ALS3','ALS4','ALS5') ",
      "AND EXISTS (SELECT 1 FROM varInfo_synthetic v ",
      "WHERE v.gene_name = 'SOD1' AND v.HighImpact = 1 ",
      "AND CASE p.IID ",
      "WHEN 'ALS1' THEN v.ALS_1 WHEN 'ALS2' THEN v.ALS_2 ",
      "WHEN 'ALS3' THEN v.ALS_3 WHEN 'ALS4' THEN v.ALS_4 ",
      "WHEN 'ALS5' THEN v.ALS_5 END > 0)"
    ),
    name      = "query_pheno",
    arguments = list(
      sql = ellmer::type_string(
        "A valid SQLite SELECT statement joining varInfo_synthetic with pheno or SM."
      )
    )
  )
}

make_sex_distribution_tool <- function(gdb_obj) {
  sex_fun <- function(dummy = "run") {
    result <- tryCatch({
      dbGetQuery(gdb_obj,
                 "SELECT
           CASE sex WHEN 1 THEN 'Female' WHEN 2 THEN 'Male' ELSE 'Unknown' END AS sex,
           COUNT(*) AS n_samples,
           SUM(CASE WHEN pheno = 1 THEN 1 ELSE 0 END) AS n_cases,
           SUM(CASE WHEN pheno = 2 THEN 1 ELSE 0 END) AS n_controls
         FROM pheno
         GROUP BY sex")
    }, error = function(e) data.frame(error = e$message))
    as.character(toJSON(result, auto_unbox = TRUE))
  }
  
  tool(
    sex_fun,
    description = paste0(
      "Get the sex distribution of all samples in the dataset. ",
      "Returns counts of female and male samples split by ALS case vs control. ",
      "Use for questions about sex distribution of carriers."
    ),
    name      = "get_sex_distribution",
    arguments = list(
      dummy = ellmer::type_string("Pass any string to trigger this tool.")
    )
  )
}
