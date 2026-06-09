## ============================================================
## config.R  –  Agentic benchmark pipeline
## ============================================================

## ── Backends ─────────────────────────────────────────────────
## Options: "agentic_single", "agentic_dual"
BACKENDS_TO_RUN <- c("agentic_single", "agentic_dual")

## ── Models ───────────────────────────────────────────────────
MODELS_TO_TEST <- c("llama3.1:8b")

## ── Dual backend model grid ───────────────────────────────────
## Only llama3.1:8b -> llama3.1:8b for this run
ORCH_MODELS_TO_TEST <- c("llama3.1:8b")
SUB_MODELS_TO_TEST  <- c("llama3.1:8b")

## ── Judge model ───────────────────────────────────────────────
JUDGE_MODEL <- "gemma3"

## ── Service URLs ─────────────────────────────────────────────
MCP_BASE   <- "http://localhost:8008"
OLLAMA_URL <- "http://localhost:11434"

## ── Paths ────────────────────────────────────────────────────
PROMPTS_FILE  <- "~/project_ALS_databse/scripts/agentic/prompts.txt"
BENCHMARKS_MD <- "~/project_ALS_databse/references/benchmarks_agentic.md"
BENCHMARK_DIR <- "~/project_ALS_databse/analysis/benchmark_agentic_testing"
GRADING_DIR   <- "~/project_ALS_databse/analysis/benchmark_agentic_grading"