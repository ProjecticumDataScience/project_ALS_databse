# ALS Variant Chatbot — Benchmark Pipeline

Automated benchmarking pipeline that evaluates local LLMs on genomic variant queries
against the Project MinE ALS dataset. Tests multiple backends side-by-side and produces
graded results and comparison plots.

---

## Pipeline overview

The diagram below shows the full pipeline flow — inputs feed into the orchestrator,
which runs each backend in sequence, collects results into a combined CSV, grades them
with a judge LLM, and produces comparison plots.

```
pipeline_diagram/pipeline_diagram.png
```

To regenerate the diagram:

```r
source("pipeline_diagram/pipeline_diagram.R")
```

---

## Directory structure

```
scripts/benchmark/
├── config.R                         ← the only file you normally edit
├── prompts.txt                      ← data description + LLM instructions
├── run_pipeline.R                   ← master script, sources everything
├── 01_benchmark.R                   ← runs questions across models + backends
├── 02_grade.R                       ← auto-grades with judge LLM + manual review
├── 03_visualise.R                   ← produces comparison plots
├── backends/
│   ├── backend_querychat.R          ← querychat framework (SQL tooling)
│   ├── backend_mcp.R                ← mcpo REST server (Python)
│   └── backend_ellmer.R             ← raw ellmer tool-calling, no framework
├── mcp_server_setup/
│   ├── server.py                    ← FastMCP server exposing the variant database
│   └── start_services.sh            ← launches mcpo + Open WebUI
└── pipeline_diagram/
    ├── pipeline_diagram.R           ← generates the diagram
    └── pipeline_diagram.png         ← current rendered diagram
```

Output is written to:

```
analysis/
├── benchmark_testing/
│   └── benchmark_<backends>_<datetime>/
│       ├── all_backends_combined.csv    ← combined results across all backends
│       └── <model>.txt                 ← full output per model
└── benchmark_grading/
    └── grading_<datetime>/
        ├── autograded_<datetime>.csv
        └── finalgraded_<datetime>.csv
```

---

## Quick start

### 1. Configure

Open `config.R` — this is the only file you need to touch for a normal run:

```r
## Which backends to run (all three, or any subset)
BACKENDS_TO_RUN <- c("querychat", "mcp", "ellmer")

## Which LLMs to test — any model available in Ollama works
MODELS_TO_TEST <- c("llama3.1:8b", "mistral", "deepseek-r1:8b", "qwen3:8b", "llama3.2")

## Judge model for auto-grading
JUDGE_MODEL <- "gemma3"

## MCP server URLs (only used when "mcp" is in BACKENDS_TO_RUN)
MCP_URL    <- "http://localhost:8000"
OLLAMA_URL <- "http://localhost:11434"

## Output paths
BENCHMARK_DIR <- "~/project_ALS_databse/analysis/benchmark_testing"
GRADING_DIR   <- "~/project_ALS_databse/analysis/benchmark_grading"
```

### 2. Start MCP server (only needed for the `mcp` backend)

```bash
cd scripts/benchmark/mcp_server_setup
bash start_services.sh
```

The script sets `RVAT_GDB_PATH` automatically and runs a health check on
`localhost:8000` before returning.

### 3. Run the pipeline

**From RStudio** — open `run_pipeline.R` and hit Source (`Ctrl+Shift+S`).

**From the terminal:**

```bash
# Full pipeline — all backends and models from config.R
Rscript run_pipeline.R

# Equivalent explicit flag
Rscript run_pipeline.R --all-backends

# Single backend only
Rscript run_pipeline.R --backend mcp
Rscript run_pipeline.R --backend querychat
Rscript run_pipeline.R --backend ellmer

# Override models on the fly (works with any backend flag)
Rscript run_pipeline.R --backend mcp llama3.1:8b mistral
Rscript run_pipeline.R --all-backends llama3.1:8b

# Re-plot from existing graded files — skip benchmark and grading
Rscript run_pipeline.R --visualise-only
```

---

## Backends

All three backends query the same `varInfo_synthetic` table and receive identical
questions, prompts, and grading rubric, making results directly comparable.

| Backend | How it works | Requires |
|---|---|---|
| `querychat` | querychat framework manages SQL generation and tool routing | `rvat`, `rvatData`, Ollama |
| `mcp` | HTTP calls to a Python FastMCP server via mcpo; Ollama classifies the question and summarises the result | mcpo on `localhost:8000`, Ollama |
| `ellmer` | Raw ellmer tool-calling — no framework layer; LLM decides when to call the database directly | `rvat`, `rvatData`, Ollama |

### Database access per backend

- **querychat** and **ellmer** read `rvatData.gdb` directly from R using `rvat`
- **mcp** talks to `server.py` which connects to `rvatData.gdb` via SQLite

> **Important:** `varInfo_synthetic` (with the synthetic ALS/Control genotype columns)
> must exist in `rvatData.gdb` before running the MCP backend. Run
> `create_varInfo_synthetic.R` once to write it, or let the querychat/ellmer backend
> run first — they create it automatically each time.

---

## Data flow

Each pipeline run produces a clear chain of file handoffs:

```
01_benchmark.R
    └── writes → all_backends_combined.csv
                        │
                        ▼
               02_grade.R  (reads combined CSV)
                    └── writes → finalgraded_<datetime>.csv
                                        │
                                        ▼
                               03_visualise.R  (auto-discovers all finalgraded CSVs)
                                    └── writes → 5 PNG plots
```

`03_visualise.R` automatically discovers **all** `finalgraded_*.csv` files under
`GRADING_DIR` — including from previous runs — and averages scores across them before
plotting. This means running the pipeline multiple times accumulates results rather
than overwriting them.

---

## Benchmark questions

15 questions across three categories:

| ID | Category | Question |
|---|---|---|
| L1 | Lookup | How many variants are in NEK1? |
| L2 | Lookup | Select variants in NEK1 with HighImpact and CADDphred > 20 |
| L3 | Lookup | How many variants in TARDBP are predicted deleterious by SIFT? |
| L4 | Lookup | Which high-impact variants have at least one homozygous ALS patient? |
| L5 | Lookup | What are the ten most deleterious variants in ABCA4? |
| A1 | Analytical | What is the variant with the highest allele frequency? |
| A2 | Analytical | Average allele frequency for synonymous, moderate, and high-impact variants? |
| A3 | Analytical | How many high-impact variants does ALS_1 carry? |
| A4 | Analytical | What is the total burden of cases versus controls? |
| A5 | Analytical | Are there more variants in cases than controls? |
| U1 | Unanswerable | What is the average age of ALS cases? |
| U2 | Unanswerable | What is the allele frequency of VAR_id 30 in Europeans? |
| U3 | Unanswerable | Which variants are both synonymous and high impact? |
| U4 | Unanswerable | Which variants are most important? |
| U5 | Unanswerable | Is VAR_id 100 previously reported as pathogenic? |

---

## Grading

Each response is scored on four pass/fail criteria by a judge LLM (default: `gemma3`),
using the expected SQL and correct answers from `references/benchmarks.md` as ground truth.

| Criterion | What it checks |
|---|---|
| `grade_answer` | Is the final answer correct or appropriately refused? |
| `grade_minimal_response` | Is the response concise (1–3 sentences)? |
| `grade_hallucination` | Does it avoid invented data, wrong column names, or genotype misinterpretation? |
| `grade_sql` | Is the SQL query correct and logically sound? |

**Total score: 0–4 per question.**

Any rows the judge LLM cannot parse are flagged `NA` and the script drops into an
interactive terminal prompt for manual review before saving the final graded CSV.

---

## Plots produced

`03_visualise.R` detects which models and backends are present in the data and scales
all plots accordingly — no hard-coded model names anywhere.

| File | What it shows |
|---|---|
| `plot_overall_scores.png` | Average total score per model, faceted by backend |
| `plot_backend_comparison.png` | querychat vs MCP vs ellmer side-by-side per model |
| `plot_category_scores.png` | Score per question category (lookup / analytical / unanswerable) |
| `plot_heatmap.png` | Score per question x model heatmap (all backends) |
| `plot_criteria_scores.png` | Pass rate per grading criterion per model |

---

## Editing prompts

`prompts.txt` contains two sections separated by `===EXTRA_INSTRUCTIONS===`.
Edit freely — no R syntax required.

```
===DATA_DESCRIPTION===
Describe the database columns, encoding, and important caveats here.

===EXTRA_INSTRUCTIONS===
Rules for how the LLM should respond — format, refusals, ambiguity handling.
```

Both sections are loaded at the start of every benchmark run, so changes take
effect immediately without touching any R scripts.

---

## Adding a new backend

1. Create `backends/backend_<name>.R`
2. Implement two functions:
   - `<name>_setup(model_name, ...)` → returns a session object, or `NULL` on failure
   - `<name>_ask(session, question)` → returns `list(response = "...", full = "...")`
3. Add `"<name>"` to `BACKENDS_TO_RUN` in `config.R`
4. Add the backend to both dispatchers in `01_benchmark.R` (`setup_session` and `ask_question`)

The `full` field should capture the complete interaction log (SQL, raw result, final
answer) — this is what the grader reads. The `response` field is the final answer only.

---

## Dependencies

**R packages**

```r
install.packages(c("ellmer", "querychat", "DBI", "httr2", "jsonlite",
                   "ollamar", "R.utils", "ggplot2", "dplyr", "tidyr",
                   "scales", "DiagrammeR"))
remotes::install_github("KennaLab/rvat")
remotes::install_github("KennaLab/rvatData")
```

**Python (for MCP backend)**

```bash
pip install fastmcp mcpo
```

**Local services**
- [Ollama](https://ollama.com) running on `localhost:11434`
- Models pulled: `ollama pull llama3.1:8b` etc.
