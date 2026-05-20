## ============================================================
## config.R  –  Edit this file to configure the pipeline
## ============================================================

## ── Backend ──────────────────────────────────────────────────
## Which backend to benchmark. Options: "querychat" or "mcp"
BACKEND <- "mcp"

## MCP/Ollama URLs (only used when BACKEND = "mcp")
MCP_URL    <- "http://localhost:8000"
OLLAMA_URL <- "http://localhost:11434"

## ── Models ───────────────────────────────────────────────────
## Models to benchmark. Add or remove as needed.
## Any model available in your local Ollama installation works.
MODELS_TO_TEST <- c(
  "llama3.1:8b"
)

## Model used to auto-grade responses
JUDGE_MODEL <- "gemma3"

## ── Paths ────────────────────────────────────────────────────
PROMPTS_FILE  <- "~/project_ALS_databse/scripts/benchmark/Prompts.txt"
BENCHMARKS_MD <- "~/project_ALS_databse/references/benchmarks.md"
BENCHMARK_DIR <- "~/project_ALS_databse/analysis/benchmark_testing"
GRADING_DIR   <- "~/project_ALS_databse/analysis/benchmark_grading"

## ── Graded files ──────────────────────────────────────────────
## 03_visualise.R automatically discovers all finalgraded_*.csv
## files under GRADING_DIR. Nothing to configure here.
