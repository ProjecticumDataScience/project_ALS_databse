## ============================================================
## config.R  –  Edit this file to configure the pipeline
## ============================================================

## ── Backends ─────────────────────────────────────────────────
## Which backends to run. All run in sequence and their results
## are combined before grading and visualisation.
## Options: "querychat", "mcp", "ellmer", "dual", "mcp_dual"
BACKENDS_TO_RUN <- c("mcp_dual", "querychat", "mcp", "ellmer", "dual")

## ── Models (single-model backends) ───────────────────────────
## Used by querychat, mcp, and ellmer backends.
MODELS_TO_TEST <- c(
  "llama3.1:8b"
)

## ── Dual backend model grid ───────────────────────────────────
## All combinations of ORCH x SUB are benchmarked automatically.
## Each combination is labelled "orch -> sub" in the results.
## Pull before using: ollama pull <model>
ORCH_MODELS_TO_TEST <- c(
  "llama3.1:8b"
)

SUB_MODELS_TO_TEST <- c(
  "duckdb-nsql"
)

## ── Judge model (for auto-grading) ───────────────────────────
JUDGE_MODEL <- "gemma3"

## ── Service URLs ─────────────────────────────────────────────
## Only used when "mcp" is in BACKENDS_TO_RUN
MCP_URL    <- "http://localhost:8000"
OLLAMA_URL <- "http://localhost:11434"

## ── Paths ────────────────────────────────────────────────────
PROMPTS_FILE  <- "~/project_ALS_databse/scripts/benchmark/prompts.txt"
BENCHMARKS_MD <- "~/project_ALS_databse/references/benchmarks.md"
BENCHMARK_DIR <- "~/project_ALS_databse/analysis/benchmark_testing"
GRADING_DIR   <- "~/project_ALS_databse/analysis/benchmark_grading"
