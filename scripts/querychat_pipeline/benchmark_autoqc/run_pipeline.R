## ============================================================
## run_pipeline.R
## Master script – sources all three pipeline steps in order.
##
## USAGE (RStudio):
##   1. Edit config.R to set your models, paths, etc.
##   2. Source this file: source("run_pipeline.R")
##
## USAGE (command line / Rscript):
##   Rscript run_pipeline.R                      # uses MODELS_TO_TEST from config.R
##   Rscript run_pipeline.R mistral              # benchmarks a single model
##   Rscript run_pipeline.R llama3.1:8b qwen3:8b # benchmarks two specific models
##
## VISUALISE ONLY (skip benchmarking + grading):
##   Rscript run_pipeline.R --visualise-only
## ============================================================

## ── Locate scripts relative to this file ─────────────────────
## Works whether you source() in RStudio or call via Rscript.
script_dir <- tryCatch(
  dirname(normalizePath(sys.frame(1)$ofile)),   # sourced
  error = function(e) {
    args <- commandArgs(trailingOnly = FALSE)
    file_flag <- grep("--file=", args, value = TRUE)
    if (length(file_flag)) dirname(normalizePath(sub("--file=", "", file_flag)))
    else getwd()
  }
)

## ── Load config ───────────────────────────────────────────────
source(file.path(script_dir, "config.R"))

## ── Handle CLI arguments ──────────────────────────────────────
cli_args <- commandArgs(trailingOnly = TRUE)

visualise_only <- "--visualise-only" %in% cli_args
cli_models     <- cli_args[!cli_args %in% "--visualise-only"]

if (length(cli_models) > 0) {
  cat("CLI override: benchmarking model(s):", paste(cli_models, collapse = ", "), "\n")
  MODELS_TO_TEST <- cli_models
}

## ── Step 1: Benchmark ─────────────────────────────────────────
if (!visualise_only) {
  cat("\n========== STEP 1: BENCHMARK ==========\n")
  source(file.path(script_dir, "01_benchmark.R"))

  ## 01_benchmark.R sets BENCHMARK_CSV; pass it forward to grading
  ## (already in global env, nothing extra needed)

  ## ── Step 2: Grade ─────────────────────────────────────────
  cat("\n========== STEP 2: GRADE ==========\n")
  source(file.path(script_dir, "02_grade.R"))

  ## 02_grade.R sets GRADED_FINAL_CSV via <<-
  ## Override GRADED_FILES so the visualiser uses the fresh run
  GRADED_FILES <- GRADED_FINAL_CSV
}

## ── Step 3: Visualise ─────────────────────────────────────────
cat("\n========== STEP 3: VISUALISE ==========\n")
source(file.path(script_dir, "03_visualise.R"))

cat("\n========== PIPELINE COMPLETE ==========\n")
cat("Benchmark results  :", if (exists("BENCHMARK_CSV")) BENCHMARK_CSV else "(skipped)", "\n")
cat("Final graded file  :", if (exists("GRADED_FINAL_CSV")) GRADED_FINAL_CSV else GRADED_FILES, "\n")
cat("Plots saved to     :", path.expand(GRADING_DIR), "\n")
