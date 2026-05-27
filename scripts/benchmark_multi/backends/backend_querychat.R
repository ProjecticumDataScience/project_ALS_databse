## ============================================================
## backends/backend_querychat.R
## Adapter that runs one benchmark question via querychat+ollama.
## Returns a named list: list(response = "...", full = "...")
## ============================================================

library(ellmer)
library(querychat)
library(R.utils)

## Called once per model to set up the QueryChat session.
querychat_setup <- function(model_name, gdb, data_description, extra_instructions) {
  ollama_client <- tryCatch({
    chat_ollama(
      model  = model_name,
      params = ellmer::params(temperature = 0.1, num_predict = 200),
      api_args = list(timeout = 300)   ## 5 min — covers cold model load
    )
  }, error = function(e) {
    cat("ERROR: Could not load model", model_name, "-", e$message, "\n")
    return(NULL)
  })
  
  if (is.null(ollama_client)) return(NULL)
  
  QueryChat$new(
    data_source           = gdb,
    table_name            = "varInfo_synthetic",
    client                = ollama_client,
    data_description      = data_description,
    extra_instructions    = extra_instructions,
    categorical_threshold = 50,
    greeting              = "Welcome!"
  )
}

## Called once per question. Returns list(response, full).
querychat_ask <- function(qc, question) {
  client <- qc$client(tools = "query")
  
  tryCatch({
    withTimeout({
      captured <- capture.output({
        resp <- client$chat(question, echo = "all")
      })
      list(
        response = unclass(resp),
        full     = paste(captured, collapse = "\n")
      )
    }, timeout = 300, onTimeout = "error")   ## match the HTTP timeout
  }, error = function(e) {
    list(
      response = paste("TIMEOUT/ERROR:", e$message),
      full     = paste("TIMEOUT/ERROR:", e$message)
    )
  })
}
