## ============================================================
## 01_benchmark.R
## Run LLM benchmark across all models defined in config.R
## ============================================================

library(ellmer)
library(querychat)
library(rollama)
library(DBI)
library(rvat)
library(rvatData)
library(R.utils)

## ── Load prompts from prompts.txt ────────────────────────────
stopifnot(file.exists(path.expand(PROMPTS_FILE)))
raw      <- paste(readLines(path.expand(PROMPTS_FILE)), collapse = "\n")
parts    <- strsplit(raw, "===EXTRA_INSTRUCTIONS===")[[1]]
data_description   <- trimws(sub(".*===DATA_DESCRIPTION===\n", "", parts[1]))
extra_instructions <- trimws(parts[2])
cat("Prompts loaded from:", PROMPTS_FILE, "\n")

## ── Setup database ───────────────────────────────────────────
gdb <- gdb(rvat_example("rvatData.gdb"))
vi  <- dbGetQuery(gdb, "SELECT * FROM varInfo")
set.seed(123)
n_rows <- nrow(vi)
geno_als     <- replicate(5, sample(0:2, n_rows, replace = TRUE))
colnames(geno_als)     <- paste0("ALS_", 1:5)
geno_control <- replicate(5, sample(0:2, n_rows, replace = TRUE))
colnames(geno_control) <- paste0("Control_", 1:5)
vi_updated <- cbind(vi, geno_als, geno_control)
dbWriteTable(gdb, "varInfo_synthetic", vi_updated, overwrite = TRUE)

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

## ── Benchmark function ────────────────────────────────────────
run_benchmark <- function(model_name, questions, gdb, data_description, extra_instructions) {
  cat("\n\n========================================\n")
  cat("Testing model:", model_name, "\n")
  cat("========================================\n")

  ollama_client <- tryCatch({
    chat_ollama(
      model  = model_name,
      params = ellmer::params(temperature = 0.1, num_predict = 200)
    )
  }, error = function(e) {
    cat("ERROR: Could not load model", model_name, "-", e$message, "\n")
    return(NULL)
  })

  if (is.null(ollama_client)) return(NULL)

  qc <- QueryChat$new(
    data_source          = gdb,
    table_name           = "varInfo_synthetic",
    client               = ollama_client,
    data_description     = data_description,
    extra_instructions   = extra_instructions,
    categorical_threshold = 50,
    greeting             = "Welcome!"
  )

  results <- list()

  for (q in questions) {
    cat("  Running:", q$id, "-", q$question, "\n")

    client <- qc$client(tools = "query")

    full_output <- tryCatch({
      withTimeout({
        captured <- capture.output({
          resp <- client$chat(q$question, echo = "all")
        })
        list(
          response = unclass(resp),
          full     = paste(captured, collapse = "\n")
        )
      }, timeout = 90, onTimeout = "error")
    }, error = function(e) {
      list(
        response = paste("TIMEOUT/ERROR:", e$message),
        full     = paste("TIMEOUT/ERROR:", e$message)
      )
    })

    results[[q$id]] <- list(
      id       = q$id,
      category = q$category,
      question = q$question,
      full     = full_output$full,
      response = full_output$response,
      model    = model_name
    )

    Sys.sleep(3)
  }

  return(results)
}

## ── Create output folder ──────────────────────────────────────
BENCHMARK_TIMESTAMP <- format(Sys.time(), "%Y%m%d_%H%M%S")
output_dir <- path.expand(file.path(
  BENCHMARK_DIR,
  paste0("benchmark_", BENCHMARK_TIMESTAMP)
))
dir.create(output_dir, recursive = TRUE)
cat("Output folder created:", output_dir, "\n")

## ── Combined results dataframe ────────────────────────────────
all_results <- data.frame(
  id       = character(),
  category = character(),
  question = character(),
  full     = character(),
  response = character(),
  model    = character(),
  stringsAsFactors = FALSE
)

## ── Run all models ────────────────────────────────────────────
for (model_name in MODELS_TO_TEST) {
  results <- run_benchmark(model_name, benchmark_questions, gdb, data_description, extra_instructions)

  if (is.null(results)) {
    cat("Skipping", model_name, "- failed to load\n")
    next
  }

  model_name_clean <- gsub("[^a-zA-Z0-9_]", "_", model_name)

  ## Save individual TXT
  output <- c()
  output <- c(output, "BENCHMARK RESULTS")
  output <- c(output, paste("Model:", model_name))
  output <- c(output, paste("Date:", format(Sys.time(), "%Y-%m-%d %H:%M:%S")))
  output <- c(output, "================================================")
  output <- c(output, "")

  for (r in results) {
    output <- c(output, paste("ID:      ", r$id))
    output <- c(output, paste("Category:", r$category))
    output <- c(output, paste("Question:", r$question))
    output <- c(output, "--- Full output (incl. tool calls) ---")
    output <- c(output, r$full)
    output <- c(output, "--- Final response ---")
    output <- c(output, r$response)
    output <- c(output, "------------------------------------------------")
    output <- c(output, "")
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
      stringsAsFactors = FALSE
    ))
  }
}

## ── Save combined CSV ─────────────────────────────────────────
BENCHMARK_CSV <- file.path(output_dir, "all_models_combined.csv")
write.csv(all_results, BENCHMARK_CSV, row.names = FALSE)
cat("\nCombined CSV saved:", BENCHMARK_CSV, "\n")
cat("Benchmark complete! Results in:", output_dir, "\n")
