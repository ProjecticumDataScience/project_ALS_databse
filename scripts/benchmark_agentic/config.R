## ============================================================
## config.R  –  Agentic benchmark pipeline
## ============================================================

## ── Backends ─────────────────────────────────────────────────
## Options: "agentic_single", "agentic_dual", "agentic_adaptive"
BACKENDS_TO_RUN <- c("agentic_single", "agentic_dual", "agentic_adaptive")

## ── Models ───────────────────────────────────────────────────
MODELS_TO_TEST <- c("llama3.1:8b")

## ── Dual backend model grid ───────────────────────────────────
ORCH_MODELS_TO_TEST <- c("llama3.1:8b")
SUB_MODELS_TO_TEST  <- c("llama3.1:8b")    ## used for agentic_dual

## ── Adaptive backend ─────────────────────────────────────────
## LLM1 picks LLM2 dynamically:
##   run_variant_query → SUB_SQL_MODEL  (SQL specialist)
##   named tools/agentic → SUB_REASON_MODEL (reasoning)
SUB_SQL_MODEL    <- "duckdb-nsql"
SUB_REASON_MODEL <- "llama3.1:8b"

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