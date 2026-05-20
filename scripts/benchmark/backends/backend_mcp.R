## ============================================================
## backends/backend_mcp.R
## Adapter that runs one benchmark question via mcpo + Ollama.
## Mirrors the querychat adapter interface exactly:
##   mcp_setup() → session object
##   mcp_ask(session, question) → list(response, full)
## ============================================================

library(httr2)
library(jsonlite)

## ── Internal helpers ─────────────────────────────────────────

.call_mcp <- function(tool_name, body = list(), mcp_url) {
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

.call_ollama <- function(prompt, system_prompt = NULL,
                         json_mode = FALSE, model, ollama_url) {
  body <- list(
    model   = model,
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
    resp <- request(ollama_url) |>
      req_url_path("/api/generate") |>
      req_body_json(body) |>
      req_timeout(90) |>
      req_perform()
    resp_body_json(resp)$response
  }, error = function(e) {
    paste("Ollama error:", e$message)
  })
}

## Fetch schema once from the MCP server and return as a string.
.get_schema_string <- function(mcp_url) {
  tryCatch({
    raw  <- .call_mcp("get_schema", mcp_url = mcp_url)
    cols <- fromJSON(raw)
    paste(apply(cols, 1, function(r) paste0(r["name"], " (", r["type"], ")")),
          collapse = ", ")
  }, error = function(e) {
    ## Fallback to known columns if MCP not yet reachable
    paste(
      "VAR_id (TEXT), CHROM (TEXT), POS (INTEGER), ID (TEXT),",
      "REF (TEXT), ALT (TEXT), AC (INTEGER), AN (INTEGER), AF (REAL),",
      "gene_name (TEXT), HighImpact (INTEGER), ModerateImpact (INTEGER),",
      "Synonymous (INTEGER), CADDphred (TEXT), PolyPhen (TEXT), SIFT (TEXT),",
      "ALS_1 (INTEGER), ALS_2 (INTEGER), ALS_3 (INTEGER),",
      "ALS_4 (INTEGER), ALS_5 (INTEGER),",
      "Control_1 (INTEGER), Control_2 (INTEGER), Control_3 (INTEGER),",
      "Control_4 (INTEGER), Control_5 (INTEGER)"
    )
  })
}

## Classify a question to an MCP tool + params using Ollama.
.classify_question <- function(question, schema_info, model,
                               ollama_url, data_description, extra_instructions) {
  sys <- paste0(
    "Output ONLY a JSON object with exactly two keys: 'tool' and 'params'.\n",
    "No explanation. No markdown. No extra keys.\n\n",
    "The database table is: varInfo_synthetic\n",
    "Columns: ", schema_info, "\n\n",
    "Data description:\n", data_description, "\n\n",
    "Additional rules:\n", extra_instructions, "\n\n",
    "TOOL SELECTION — follow these rules strictly:\n\n",
    "1. Any question about a SPECIFIC gene:\n",
    '   {"tool":"get_variants_by_gene","params":{"gene":"NEK1","limit":500}}\n\n',
    "2. Which gene has the most variants / top genes / ranking:\n",
    '   {"tool":"count_variants_by_gene","params":{"top_n":20}}\n\n',
    "3. Filter by impact level (HighImpact=1 / ModerateImpact=1 / Synonymous=1):\n",
    '   {"tool":"get_variants_by_impact","params":{"impact":"HIGH","limit":100}}\n\n',
    "4. Deleterious / harmful variants by predictor:\n",
    '   {"tool":"get_deleterious_variants","params":{"predictor":"SIFT","limit":100}}\n\n',
    "5. Database totals / overview / statistics:\n",
    '   {"tool":"summarize_database","params":{}}\n\n',
    "6. Anything else (allele frequency, burden, chromosome, genotypes):\n",
    '   {"tool":"query_variants","params":{"sql":"SELECT ... FROM varInfo_synthetic ..."}}\n\n',
    "For unanswerable questions (age, ethnicity, pathogenicity, etc.):\n",
    '   {"tool":"none","params":{"reason":"This information is not available in the dataset."}}\n\n',
    "Return ONLY the JSON object, nothing else."
  )

  raw <- .call_ollama(question, system_prompt = sys,
                      json_mode = TRUE, model = model, ollama_url = ollama_url)

  tryCatch({
    clean      <- gsub("```json|```", "", raw)
    clean      <- trimws(clean)
    parsed     <- fromJSON(clean, simplifyVector = FALSE)
    if (is.null(parsed$tool)) stop("No 'tool' key found")
    list(ok = TRUE, tool = parsed$tool,
         params = if (is.null(parsed$params)) list() else parsed$params)
  }, error = function(e) {
    list(ok = FALSE,
         error = paste0("Classification failed: ", e$message,
                        "\nModel returned: ", raw))
  })
}

## Summarise raw MCP result in plain English.
.summarize_result <- function(question, tool_name, result_json,
                              model, ollama_url, row_count = NULL) {
  sys <- paste(
    "You are an ALS bioinformatics assistant.",
    "Give a short, clear answer in English (max 2 sentences).",
    "Start directly with the conclusion. No SQL, JSON, or jargon."
  )

  preview    <- if (nchar(result_json) > 3000) {
    paste0(substr(result_json, 1, 3000), "\n... [result truncated]")
  } else result_json

  count_hint <- if (!is.null(row_count)) {
    paste0("\nThe exact number of rows found is: ", row_count,
           ". State this number in your answer.\n")
  } else ""

  prompt <- paste0(
    "Question: ", question,   "\n",
    "Tool used: ", tool_name, "\n",
    count_hint,
    "Result:\n", preview, "\n\n",
    "Give a short English summary."
  )

  .call_ollama(prompt, system_prompt = sys,
               model = model, ollama_url = ollama_url)
}

## ── Public interface ──────────────────────────────────────────

## Called once per model. Returns a session list with everything
## needed to ask questions (mirrors querychat_setup).
mcp_setup <- function(model_name, mcp_url, ollama_url,
                      data_description, extra_instructions) {

  ## Sanity-check: is mcpo reachable?
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

  schema_info <- .get_schema_string(mcp_url)
  cat("  MCP schema loaded. Columns:", substr(schema_info, 1, 80), "...\n")

  list(
    model_name         = model_name,
    mcp_url            = mcp_url,
    ollama_url         = ollama_url,
    schema_info        = schema_info,
    data_description   = data_description,
    extra_instructions = extra_instructions
  )
}

## Called once per question. Returns list(response, full).
mcp_ask <- function(session, question) {
  tryCatch({

    ## Step 1: classify question → tool + params
    cl <- .classify_question(
      question           = question,
      schema_info        = session$schema_info,
      model              = session$model_name,
      ollama_url         = session$ollama_url,
      data_description   = session$data_description,
      extra_instructions = session$extra_instructions
    )

    if (!cl$ok) {
      msg <- paste("Could not classify question:", cl$error)
      return(list(response = msg, full = msg))
    }

    ## Unanswerable: model correctly refused
    if (cl$tool == "none") {
      reason <- cl$params$reason %||%
        "This information is not available in the dataset."
      return(list(
        response = reason,
        full     = paste0("[tool=none] ", reason)
      ))
    }

    tool   <- cl$tool
    params <- as.list(cl$params)

    ## Step 2: call MCP tool
    raw_result <- .call_mcp(tool, params, mcp_url = session$mcp_url)

    ## Step 3: count rows if relevant
    row_count <- tryCatch({
      parsed <- fromJSON(raw_result, flatten = TRUE)
      if (is.data.frame(parsed)) nrow(parsed) else NULL
    }, error = function(e) NULL)

    ## Step 4: summarise
    summary_text <- .summarize_result(
      question    = question,
      tool_name   = tool,
      result_json = raw_result,
      model       = session$model_name,
      ollama_url  = session$ollama_url,
      row_count   = row_count
    )

    ## Full log mirrors what querychat captures (tool call + response)
    full_log <- paste0(
      "[tool=", tool, "] params=", toJSON(params, auto_unbox = TRUE), "\n",
      "--- raw result (first 2000 chars) ---\n",
      substr(raw_result, 1, 2000), "\n",
      "--- summary ---\n",
      summary_text
    )

    list(response = summary_text, full = full_log)

  }, error = function(e) {
    msg <- paste("MCP backend error:", e$message)
    list(response = msg, full = msg)
  })
}

## Null-coalescing helper (mirrors Shiny app)
`%||%` <- function(a, b) if (!is.null(a)) a else b
