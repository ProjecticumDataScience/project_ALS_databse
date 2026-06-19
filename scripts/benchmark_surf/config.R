## ============================================================
## config.R  –  Agentic benchmark pipeline  [SURF HPC server]
## ============================================================

## ── Backends ─────────────────────────────────────────────────
## Options: "agentic_single", "agentic_dual", "agentic_adaptive"
BACKENDS_TO_RUN <- c("agentic_adaptive")

## ── Models ───────────────────────────────────────────────────
MODELS_TO_TEST <- c("llama3.1:70b")

## ── Dual backend model grid ───────────────────────────────────
ORCH_MODELS_TO_TEST <- c("llama3.1:70b")
SUB_MODELS_TO_TEST  <- c("llama3.1:70b")

## ── Adaptive backend ─────────────────────────────────────────
SUB_SQL_MODEL    <- "llama3.1:70b"
SUB_REASON_MODEL <- "llama3.1:70b"

## ── Judge model ───────────────────────────────────────────────
JUDGE_MODEL <- "gemma3"

## ── Service URLs ─────────────────────────────────────────────
MCP_BASE   <- "http://localhost:8008"
OLLAMA_URL <- "http://localhost:11434"

## ── Paths ────────────────────────────────────────────────────
PROMPTS_FILE  <- "~/project_ALS_databse/scripts/agentic_surf/prompts.txt"
BENCHMARKS_MD <- "~/project_ALS_databse/references/benchmarks_agentic_surf.md"
BENCHMARK_DIR <- "~/project_ALS_databse/analysis/benchmark_surf_testing"
GRADING_DIR   <- "~/project_ALS_databse/analysis/benchmark_surf_grading"
