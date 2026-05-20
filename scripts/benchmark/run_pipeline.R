## ============================================================
## run_pipeline.R  –  Master script
##
## USAGE (RStudio):
##   1. Edit config.R — set BACKEND, MODELS_TO_TEST, paths.
##   2. source("run_pipeline.R")
##
## USAGE (command line):
##   Rscript run_pipeline.R                        # uses config.R
##   Rscript run_pipeline.R --backend mcp          # override backend
##   Rscript run_pipeline.R --backend querychat    # override backend
##   Rscript run_pipeline.R mistral                # single model
##   Rscript run_pipeline.R --visualise-only       # skip benchmark+grade
##
## Examples combining flags:
##   Rscript run_pipeline.R --backend mcp llama3.1:8b
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
visualise_only <- "--visualise-only" %in% cli_args

## --backend <name>
backend_flag_idx <- which(cli_args == "--backend")
if (length(backend_flag_idx) > 0) {
  BACKEND <- cli_args[backend_flag_idx + 1]
  cat("CLI override: backend =", BACKEND, "\n")
}

## Remaining args (not flags) treated as model overrides
cli_models <- cli_args[!cli_args %in% c("--visualise-only", "--backend") &
                        !seq_along(cli_args) %in% (backend_flag_idx + 1)]
if (length(cli_models) > 0) {
  cat("CLI override: models =", paste(cli_models, collapse = ", "), "\n")
  MODELS_TO_TEST <- cli_models
}

## ── Step 1 + 2: Benchmark & Grade ────────────────────────────
if (!visualise_only) {
  cat("\n========== STEP 1: BENCHMARK [", BACKEND, "] ==========\n")
  source(file.path(script_dir, "01_benchmark.R"))

  cat("\n========== STEP 2: GRADE ==========\n")
  source(file.path(script_dir, "02_grade.R"))

  ## Point visualiser at the fresh run only
  GRADED_FILES <- GRADED_FINAL_CSV
}

## ── Step 3: Visualise ─────────────────────────────────────────
cat("\n========== STEP 3: VISUALISE ==========\n")
source(file.path(script_dir, "03_visualise.R"))

cat("\n========== PIPELINE COMPLETE ==========\n")
cat("Backend            :", BACKEND, "\n")
cat("Benchmark results  :", if (exists("BENCHMARK_CSV")) BENCHMARK_CSV else "(skipped)", "\n")
cat("Final graded file  :", if (exists("GRADED_FINAL_CSV")) GRADED_FINAL_CSV else "(skipped)", "\n")
cat("Plots saved to     :", path.expand(GRADING_DIR), "\n")
