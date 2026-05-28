## ============================================================
## config.R  –  benchmark_multi pipeline
## Multi-table + rvat extension of the base benchmark.
## Outputs go to separate directories from the base benchmark.
## ============================================================

## ── Backends ─────────────────────────────────────────────────
## Options: "querychat", "mcp", "ellmer", "dual", "mcp_dual"
BACKENDS_TO_RUN <- c("mcp", "ellmer", "mcp_dual")

## ── Models (single-model backends) ───────────────────────────
MODELS_TO_TEST <- c(
  "llama3.1:8b"
)

## ── Dual backend model grid ───────────────────────────────────
ORCH_MODELS_TO_TEST <- c(
  "llama3.1:8b"
)

SUB_MODELS_TO_TEST <- c(
  "llama3.1:8b"
)

## ── Judge model ───────────────────────────────────────────────
JUDGE_MODEL <- "gemma3"

## ── Service URLs ─────────────────────────────────────────────
MCP_URL    <- "http://localhost:8002"
OLLAMA_URL <- "http://localhost:11434"

## ── Paths ────────────────────────────────────────────────────
## Note: BENCHMARKS_MD points to a new file benchmarks_multi.md
## that includes expected SQL/rvat approaches for all backends.
PROMPTS_FILE  <- "~/project_ALS_databse/scripts/benchmark_multi/prompts.txt"
BENCHMARKS_MD <- "~/project_ALS_databse/references/benchmarks_multi.md"
BENCHMARK_DIR <- "~/project_ALS_databse/analysis/benchmark_multi_testing"
GRADING_DIR   <- "~/project_ALS_databse/analysis/benchmark_multi_grading"
