## ============================================================
## config.R  –  Edit this file to configure the pipeline
## ============================================================

## ── Backends ─────────────────────────────────────────────────
## Which backends to run. All three run in sequence and their
## results are combined before grading and visualisation.
## Options: "querychat", "mcp", "ellmer", "dual"
BACKENDS_TO_RUN <- c("querychat", "mcp", "ellmer", "dual")

## ── Dual backend model pairing ───────────────────────────────
## Only used when "dual" is in BACKENDS_TO_RUN
ORCHESTRATOR_MODEL <- "qwen3:8b"
SUBAGENT_MODEL     <- "llama3.1:8b"

## ── Models ───────────────────────────────────────────────────
## Any model available in your local Ollama installation works.
MODELS_TO_TEST <- c(
  "llama3.1:8b",
  "mistral",
  "deepseek-r1:8b",
  "qwen3:8b",
  "llama3.2"
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
