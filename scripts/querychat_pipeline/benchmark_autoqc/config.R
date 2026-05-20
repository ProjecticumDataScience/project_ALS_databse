## ============================================================
## config.R  –  Edit this file to configure the pipeline
## ============================================================

## ── Models ───────────────────────────────────────────────────
## Models to benchmark. Add or remove as needed.
## Any model available in your local Ollama installation works.
MODELS_TO_TEST <- c(
  "llama3.1:8b",
  "mistral",
  "deepseek-r1:8b",
  "qwen3:8b",
  "llama3.2"
)

## Model used to auto-grade responses
JUDGE_MODEL <- "gemma3"

## ── Paths ────────────────────────────────────────────────────
PROMPTS_FILE  <- "~/project_ALS_databse/scripts/querychat_pipeline/benchmark_autoqc/Prompts.txt"
BENCHMARKS_MD <- "~/project_ALS_databse/references/benchmarks.md"
BENCHMARK_DIR <- "~/project_ALS_databse/analysis/benchmark_testing"
GRADING_DIR   <- "~/project_ALS_databse/analysis/benchmark_grading"

## ── Graded files ──────────────────────────────────────────────
## 03_visualise.R automatically discovers all finalgraded_*.csv
## files under GRADING_DIR. Nothing to configure here.
