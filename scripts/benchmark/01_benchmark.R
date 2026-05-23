## ============================================================
## 01_benchmark.R
## Run LLM benchmark across all models defined in config.R.
## Supports BACKEND = "querychat", "mcp", or "ellmer"
## ============================================================

## ── Load backend ─────────────────────────────────────────────
if (!exists("BACKEND"))    BACKEND    <- "querychat"
if (!exists("script_dir")) script_dir <- getwd()

backend_file <- file.path(script_dir, "backends",
                          paste0("backend_", BACKEND, ".R"))
stopifnot(file.exists(backend_file))
source(backend_file)
cat("Backend loaded:", BACKEND, "\n")

## ── Load prompts ─────────────────────────────────────────────
stopifnot(file.exists(path.expand(PROMPTS_FILE)))
raw   <- paste(readLines(path.expand(PROMPTS_FILE)), collapse = "\n")
parts <- strsplit(raw, "===EXTRA_INSTRUCTIONS===")[[1]]
data_description   <- trimws(sub(".*===DATA_DESCRIPTION===\n", "", parts[1]))
extra_instructions <- trimws(parts[2])
cat("Prompts loaded from:", PROMPTS_FILE, "\n")

## ── Database setup (querychat, ellmer, dual only) ────────────
## MCP talks to the already-running mcpo server and never needs
## a local gdb object. querychat, ellmer and dual query the gdb directly.
if (BACKEND %in% c("querychat", "ellmer", "dual")) {
  library(DBI)
  library(rvat)
  library(rvatData)
  
  gdb <- gdb(rvat_example("rvatData.gdb"))
  vi  <- dbGetQuery(gdb, "SELECT * FROM varInfo")
  set.seed(123)
  n_rows       <- nrow(vi)
  geno_als     <- replicate(5, sample(0:2, n_rows, replace = TRUE))
  colnames(geno_als)     <- paste0("ALS_", 1:5)
  geno_control <- replicate(5, sample(0:2, n_rows, replace = TRUE))
  colnames(geno_control) <- paste0("Control_", 1:5)
  vi_updated <- cbind(vi, geno_als, geno_control)
  dbWriteTable(gdb, "varInfo_synthetic", vi_updated, overwrite = TRUE)
  cat("Database ready.\n")
} else {
  gdb <- NULL
  cat("MCP backend: skipping local database setup.\n")
}

## ── Benchmark questions ───────────────────────────────────────
benchmark_questions <- list(
  list(id = "L1", category = "lookup",       question = "How many variants are in NEK1?"),
  list(id = "L2", category = "lookup",       question = "Select variants in NEK1 with HighImpact and a CADDphred > 20"),
  list(id = "L3", category = "lookup",       question = "How many variants in TARDBP are predicted deleterious by SIFT?"),
  list(id = "L4", category = "lookup",       question = "Which high-impact variants have at least one ALS patient that is homozygous for the variant?"),
  list(id = "L5", category = "lookup",       question = "What are the ten most deleterious variants in ABCA4?"),
  list(id = "A1", category = "analytical",   question = "What is the variant with the highest allele frequency?"),
  list(id = "A2", category = "analytical",   question = "What is the average allele frequency for synonymous, moderate, and high-impact variants separately?"),
  list(id = "A3", category = "analytical",   question = "How many high-impact variants does the ALS_1 patient carry?"),
  list(id = "A4", category = "analytical",   question = "What is the total burden of cases versus controls?"),
  list(id = "A5", category = "analytical",   question = "Are there more variants in cases than controls?"),
  list(id = "U1", category = "unanswerable", question = "What is the average age of ALS cases?"),
  list(id = "U2", category = "unanswerable", question = "What is the allele frequency of VAR_id 30 in Europeans?"),
  list(id = "U3", category = "unanswerable", question = "Which variants are both synonymous and high impact?"),
  list(id = "U4", category = "unanswerable", question = "Which variants are most important?"),
  list(id = "U5", category = "unanswerable", question = "Is VAR_id 100 previously reported as pathogenic?")
)

## ── Backend dispatcher ────────────────────────────────────────
setup_session <- function(model_name) {
  if (BACKEND == "querychat") {
    querychat_setup(model_name, gdb, data_description, extra_instructions)
  } else if (BACKEND == "mcp") {
    mcp_setup(model_name, MCP_URL, OLLAMA_URL,
              data_description, extra_instructions)
  } else if (BACKEND == "ellmer") {
    ellmer_setup(model_name, gdb, data_description, extra_instructions)
  } else if (BACKEND == "dual") {
    ## model_name carries "orch -> sub" — dual_setup parses it
    dual_setup(model_name, gdb, data_description, extra_instructions)
  } else {
    stop("Unknown BACKEND: ", BACKEND)
  }
}

ask_question <- function(session, question) {
  if (BACKEND == "querychat") {
    querychat_ask(session, question)
  } else if (BACKEND == "mcp") {
    mcp_ask(session, question)
  } else if (BACKEND == "ellmer") {
    ellmer_ask(session, question)
  } else if (BACKEND == "dual") {
    dual_ask(session, question)
  } else {
    stop("Unknown BACKEND: ", BACKEND)
  }
}

## ── Run benchmark ─────────────────────────────────────────────
run_benchmark <- function(model_name, questions) {
  cat("\n\n========================================\n")
  cat("Backend:", BACKEND, "| Model:", model_name, "\n")
  cat("========================================\n")
  
  session <- setup_session(model_name)
  if (is.null(session)) {
    cat("Skipping", model_name, "- session setup failed\n")
    return(NULL)
  }
  
  results <- list()
  
  for (q in questions) {
    cat("  Running:", q$id, "-", q$question, "\n")
    out <- ask_question(session, q$question)
    results[[q$id]] <- list(
      id       = q$id,
      category = q$category,
      question = q$question,
      full     = out$full,
      response = out$response,
      model    = model_name,
      backend  = BACKEND
    )
    Sys.sleep(3)
  }
  
  return(results)
}

## ── Create output folder ──────────────────────────────────────
BENCHMARK_TIMESTAMP <- format(Sys.time(), "%Y%m%d_%H%M%S")
output_dir <- path.expand(file.path(
  BENCHMARK_DIR,
  paste0("benchmark_", BACKEND, "_", BENCHMARK_TIMESTAMP)
))
dir.create(output_dir, recursive = TRUE)
cat("Output folder:", output_dir, "\n")

## ── Combined results dataframe ────────────────────────────────
all_results <- data.frame(
  id       = character(),
  category = character(),
  question = character(),
  full     = character(),
  response = character(),
  model    = character(),
  backend  = character(),
  stringsAsFactors = FALSE
)

## ── Build model list for this backend ───────────────────────
## Dual backend iterates over all ORCH x SUB combinations.
## All other backends use MODELS_TO_TEST.
models_for_this_backend <- if (BACKEND == "dual") {
  orch_sub_pairs <- expand.grid(
    orch = ORCH_MODELS_TO_TEST,
    sub  = SUB_MODELS_TO_TEST,
    stringsAsFactors = FALSE
  )
  ## Label format: "orch -> sub" — used as the model name in results
  paste0(orch_sub_pairs$orch, " -> ", orch_sub_pairs$sub)
} else {
  MODELS_TO_TEST
}

## ── Run all models ────────────────────────────────────────────
for (model_name in models_for_this_backend) {
  results <- run_benchmark(model_name, benchmark_questions)
  if (is.null(results)) next
  
  model_name_clean <- gsub("[^a-zA-Z0-9_]", "_", model_name)
  
  output <- c(
    "BENCHMARK RESULTS",
    paste("Backend:", BACKEND),
    paste("Model:  ", model_name),
    paste("Date:   ", format(Sys.time(), "%Y-%m-%d %H:%M:%S")),
    "================================================", ""
  )
  for (r in results) {
    output <- c(output,
                paste("ID:      ", r$id),
                paste("Category:", r$category),
                paste("Question:", r$question),
                "--- Full output ---", r$full,
                "--- Final response ---", r$response,
                "------------------------------------------------", ""
    )
  }
  txt_file <- file.path(output_dir, paste0(model_name_clean, ".txt"))
  writeLines(output, txt_file)
  cat("TXT saved:", txt_file, "\n")
  
  for (r in results) {
    all_results <- rbind(all_results, data.frame(
      id       = r$id,
      category = r$category,
      question = r$question,
      full     = r$full,
      response = r$response,
      model    = model_name,
      backend  = BACKEND,
      stringsAsFactors = FALSE
    ))
  }
}

## ── Save combined CSV ─────────────────────────────────────────
BENCHMARK_CSV <- file.path(output_dir, "all_models_combined.csv")
write.csv(all_results, BENCHMARK_CSV, row.names = FALSE)
cat("\nCombined CSV saved:", BENCHMARK_CSV, "\n")
cat("Benchmark complete! Results in:", output_dir, "\n")
