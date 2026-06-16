## ============================================================
## run_pipeline.R  –  Master script
##
## USAGE (RStudio):
##   1. Edit config.R — set BACKENDS_TO_RUN, MODELS_TO_TEST, paths.
##   2. source("run_pipeline.R")
##
## USAGE (command line):
##
##   Run all backends from config.R, all models from config.R:
##     Rscript run_pipeline.R
##     Rscript run_pipeline.R --all-backends
##
##   Run a single backend:
##     Rscript run_pipeline.R --backend mcp
##     Rscript run_pipeline.R --backend querychat
##
##   Override models (works with any backend flag):
##     Rscript run_pipeline.R --backend mcp llama3.1:8b mistral
##     Rscript run_pipeline.R --all-backends llama3.1:8b
##
##   Skip benchmarking and grading, just re-plot:
##     Rscript run_pipeline.R --visualise-only
## ============================================================

## ── Locate scripts ────────────────────────────────────────────
script_dir <- tryCatch(
  dirname(normalizePath(sys.frame(1)$ofile)),
  error = function(e) {
    args      <- commandArgs(trailingOnly = FALSE)
    file_flag <- grep("--file=", args, value = TRUE)
    if (length(file_flag)) dirname(normalizePath(sub("--file=", "", file_flag)))
    else getwd()
  }
)

## ── Load config ───────────────────────────────────────────────
source(file.path(script_dir, "config.R"))

## ── Parse CLI args ────────────────────────────────────────────
cli_args       <- commandArgs(trailingOnly = TRUE)
known_flags    <- c("--all-backends", "--backend", "--visualise-only")
visualise_only <- "--visualise-only" %in% cli_args

## --backend <name>  →  run only that one backend
backend_flag_idx <- which(cli_args == "--backend")
if (length(backend_flag_idx) > 0) {
  backend_val     <- cli_args[backend_flag_idx + 1]
  BACKENDS_TO_RUN <- backend_val
  cat("CLI override: backend =", BACKENDS_TO_RUN, "\n")
}

## --all-backends  →  use full BACKENDS_TO_RUN list from config.R (default anyway)
## Listed explicitly here so users can be intentional about it.
if ("--all-backends" %in% cli_args) {
  cat("Running all backends from config.R:",
      paste(BACKENDS_TO_RUN, collapse = ", "), "\n")
}

## Any remaining args that are not flags or flag values = model overrides
flag_value_positions <- if (length(backend_flag_idx) > 0) backend_flag_idx + 1 else integer(0)
cli_models <- cli_args[
  !cli_args %in% known_flags &
    !seq_along(cli_args) %in% flag_value_positions
]
if (length(cli_models) > 0) {
  cat("CLI override: models =", paste(cli_models, collapse = ", "), "\n")
  MODELS_TO_TEST <- cli_models
}

## ── Step 1: Benchmark all backends, combine into one CSV ─────
if (!visualise_only) {
  
  all_combined <- data.frame(
    id       = character(),
    category = character(),
    question = character(),
    full     = character(),
    response = character(),
    model    = character(),
    backend  = character(),
    stringsAsFactors = FALSE
  )
  
  RUN_TIMESTAMP <- format(Sys.time(), "%Y%m%d_%H%M%S")
  combined_dir  <- path.expand(file.path(
    BENCHMARK_DIR,
    paste0("benchmark_", paste(BACKENDS_TO_RUN, collapse = "_"), "_", RUN_TIMESTAMP)
  ))
  dir.create(combined_dir, recursive = TRUE)
  cat("\nRun folder:", combined_dir, "\n")
  cat("Backends  :", paste(BACKENDS_TO_RUN, collapse = ", "), "\n")
  cat("Models    :", paste(MODELS_TO_TEST,  collapse = ", "), "\n\n")
  
  for (backend in BACKENDS_TO_RUN) {
    cat("\n========== BENCHMARK [", backend, "] ==========\n")
    BACKEND <- backend
    source(file.path(script_dir, "01_benchmark.R"))
    
    ## Read back what 01_benchmark.R wrote and append to combined
    backend_results <- read.csv(BENCHMARK_CSV)
    all_combined    <- rbind(all_combined, backend_results)
    cat("  Added", nrow(backend_results), "rows from", backend, "\n")
  }
  
  ## Single combined CSV — this is what grading and visualisation use
  BENCHMARK_CSV <- file.path(combined_dir, "all_backends_combined.csv")
  write.csv(all_combined, BENCHMARK_CSV, row.names = FALSE)
  cat("\nCombined CSV (", nrow(all_combined), "rows ):", BENCHMARK_CSV, "\n")
  
  ## ── Step 2: Grade ─────────────────────────────────────────
  cat("\n========== GRADE ==========\n")
  source(file.path(script_dir, "02_grade.R"))
  
  GRADED_FILES <- GRADED_FINAL_CSV
}

## ── Step 3: Visualise ─────────────────────────────────────────
cat("\n========== VISUALISE ==========\n")
source(file.path(script_dir, "03_visualise.R"))

cat("\n========== PIPELINE COMPLETE ==========\n")
cat("Backends   :", paste(BACKENDS_TO_RUN, collapse = " + "), "\n")
cat("Models     :", paste(MODELS_TO_TEST,  collapse = ", "), "\n")
cat("Results    :", if (exists("BENCHMARK_CSV")) BENCHMARK_CSV else "(skipped)", "\n")
cat("Graded     :", if (exists("GRADED_FINAL_CSV")) GRADED_FINAL_CSV else "(skipped)", "\n")
cat("Plots      :", path.expand(GRADING_DIR), "\n")