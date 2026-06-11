# Benchmark — Agentic Pipeline

Automated benchmark pipeline for evaluating the agentic LLM variant assistant  
across 80 questions in 7 categories, graded by a judge LLM (gemma3).

---

## Quick start

```r
# In RStudio — runs all configured backends sequentially
source("~/project_ALS_databse/scripts/benchmark_agentic/run_pipeline.R")
```

---

## Prerequisites

1. **All agentic services running** (see `scripts/agentic/README.md`)
2. **Ollama running** with the models you want to benchmark
3. **Judge model available:** `ollama pull gemma3`
4. **R packages:** `dplyr`, `ggplot2`, `httr2`, `jsonlite`

---

## Configuration (`config.R`)

Key settings to change for different runs:

```r
## Which backends to run
BACKENDS_TO_RUN <- c("agentic_single", "agentic_dual", "agentic_adaptive")

## Orchestrator model (LLM1)
ORCH_MODELS_TO_TEST <- c("llama3.1:8b")

## Sub-model for dual pipeline (LLM2)
SUB_MODELS_TO_TEST <- c("llama3.1:8b")

## Adaptive pipeline specialists
SUB_SQL_MODEL    <- "duckdb-nsql"   ## for run_variant_query
SUB_REASON_MODEL <- "llama3.1:8b"  ## for agentic reasoning

## Judge model
JUDGE_MODEL <- "gemma3"

## Service URLs
MCP_BASE   <- "http://localhost:8008"
OLLAMA_URL <- "http://localhost:11434"
```

### Running on a different model (e.g. llama3.1:70b on SURF)

```r
ORCH_MODELS_TO_TEST <- c("llama3.1:70b")
SUB_MODELS_TO_TEST  <- c("llama3.1:70b")
SUB_SQL_MODEL       <- "duckdb-nsql"
SUB_REASON_MODEL    <- "llama3.1:70b"
OLLAMA_URL          <- "http://surf-server-address:11434"  ## update this
```

---

## Pipeline steps

### 1. `01_benchmark.R` — Run questions

Runs 80 questions across all configured backends and models.  
Saves results to `BENCHMARK_DIR/benchmark_{backend}_{timestamp}/`.

**Output:** `all_backends_combined.csv` with columns:
`id, category, question, full, response, model, backend, elapsed_sec`

**Categories (80 questions total):**

| Category | IDs | n | Description |
|----------|-----|---|-------------|
| simple | S01–S16 | 16 | Single-table variant queries |
| analytical | A01–A17 | 17 | Aggregations and calculations |
| complex | C01–C18 | 18 | Multi-step SQL |
| phenotype | P01–P06 | 6 | Multi-table joins with pheno |
| annotation_trap | T01–T03 | 3 | PolyPhen/SIFT code traps |
| unanswerable | U01–U15 | 15 | Hallucination resistance |
| rvat | R01–R05 | 5 | Statistical burden tests |

### 2. `02_grade.R` — Grade responses

Uses gemma3 as a judge LLM to grade each response on 4 criteria (0/1 each):

| Criterion | Description |
|-----------|-------------|
| `grade_answer` | Is the final answer correct? |
| `grade_minimal_response` | Is the response concise? |
| `grade_hallucination` | Is it free of hallucination? |
| `grade_tool` | Was the correct tool selected? |

**Total score:** sum of 4 criteria = 0–4 per question.

**Input:** `BENCHMARK_CSV` path  
**Output:** `finalgraded_{timestamp}.csv` in `GRADING_DIR`

### 3. `03_visualise.R` — Generate plots

**Input:** `GRADED_FINAL_CSV` path (set before sourcing)

```r
GRADED_FINAL_CSV <- "path/to/finalgraded_*.csv"
source("scripts/benchmark_agentic/03_visualise.R")
```

**Output plots** (saved to grading folder):

| File | Description |
|------|-------------|
| `plot_overall_scores.png` | Average score per backend |
| `plot_category_scores.png` | Score per category per backend |
| `plot_heatmap.png` | Per-question heatmap, faceted by category |
| `plot_criteria_scores.png` | Pass rate per grading criterion |
| `plot_backend_comparison.png` | Head-to-head backend comparison |
| `plot_timing.png` | Response time per category |
| `plot_correct_counts.png` | Raw correct answer count (grade_answer only) |

---

## Ground truth

Expected answers for all 80 questions are in:
```
~/project_ALS_databse/references/benchmarks_agentic.md
```

The grader uses this file to evaluate responses. Update it if you add questions  
or discover incorrect expected answers.

---

## Output directories

```
analysis/
├── benchmark_agentic_testing/
│   └── benchmark_{backend}_{timestamp}/
│       └── all_backends_combined.csv   ← raw benchmark output
└── benchmark_agentic_grading/
    └── grading_{timestamp}/
        ├── autograded_{timestamp}.csv  ← intermediate grading
        ├── finalgraded_{timestamp}.csv ← final graded CSV
        └── plot_*.png                  ← all visualisation plots
```

---

## Adding new questions

1. Add to `01_benchmark.R` in the appropriate category block:
```r
list(id="S17", category="simple",
     question="Your question here?"),
```

2. Add ground truth to `benchmarks_agentic.md`:
```markdown
## S17 — Your question here?
**Expected tool:** variant_analysis/run_variant_query
**Answer:** 42
**Grading:** grade_answer=TRUE if response states 42.
```

3. Update category counts in the summary table in `benchmarks_agentic.md`.

---

## Adding a new backend/model

1. Add to `config.R`:
```r
BACKENDS_TO_RUN <- c("agentic_single", "agentic_dual", "agentic_adaptive", "agentic_new")
```

2. Add setup logic to `backend_agentic.R` in `agentic_setup()`:
```r
} else if (grepl("\\[new\\]", model_name)) {
  orch_model <- trimws(gsub("\\s*\\[new\\]", "", model_name))
  mode       <- "dual_new"
```

3. Add model list in `01_benchmark.R`:
```r
} else if (BACKEND == "agentic_new") {
  paste0(ORCH_MODELS_TO_TEST, " [new]")
```

---

## Interpreting results

**Overall score (0–4):** Average of 4 binary criteria across all questions.  
A score of 3.0+ indicates strong performance. Below 2.5 suggests systematic failures.

**Correct counts plot:** Shows `grade_answer=TRUE` count independently of other criteria.  
A high correct count with low overall score = responses are correct but verbose or hallucinating.  
A low correct count with high overall score = impossible (answer correctness is weighted heavily).

**Hallucination rate:** Typically the weakest criterion (~44–55% pass rate on 8b models).  
This is the primary target for improvement with larger models.

**Timing:** Unanswerable questions are fastest (~15s, pre-check fires before LLM).  
Phenotype questions are slowest (~1:30, agentic loop + pheno join).  
RVAT questions vary: single gene ~1min, all genes ~5min (heavy).

---

## Benchmark history

| Run | Date | Dual | Single | Adaptive | Notes |
|-----|------|------|--------|----------|-------|
| Run 1 | Jun 8 | 1.9 | 1.9 | — | Initial 14-question set |
| Run 6 | Jun 9 | 2.88 | 3.00 | — | 75 questions, all fixes |
| Run 8 | Jun 10 | 2.97 | 2.88 | 3.12 | Adaptive introduced, ClinVar |
| Run 9 | Jun 11 | TBD | TBD | TBD | 80 questions, rvat category |