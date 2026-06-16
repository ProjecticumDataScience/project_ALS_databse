# benchmark_surf — Benchmark Pipeline (SURF HPC Server)

This is the **SURF HPC Cloud** version of the benchmark pipeline.
The posit (default) version lives in `benchmark_agentic/`.

## What's different from benchmark_agentic/

| File | Change |
|------|--------|
| `config.R` | Model = `llama3.1:70b`, paths point to `agentic_surf` and SURF output dirs |
| `01_benchmark.R` | **110 questions** (was 66) — adds `nonsense` (N) and `toolfree` (F) categories |
| `03_visualise.R` | All 9 categories supported; new Plot 8 for nonsense/toolfree breakdown |
| `backend_agentic.R` | Points to `agentic_surf/app2.R` instead of `agentic/app2.R` |
| `02_grade.R` | Copied from posit — update rubric for new categories if needed |
| `run_pipeline.R` | Identical to posit version |

## Question categories (110 total)

| Prefix | Category | Count |
|--------|----------|-------|
| S | Simple | 16 |
| A | Analytical | 17 |
| C | Complex | 18 |
| P | Phenotype | 6 |
| T | Annotation trap | 3 |
| U | Unanswerable | 15 |
| R | RVAT statistical | 5 |
| N | Nonsense | 15 |
| F | Toolfree | 15 |

## Usage

```bash
# Full pipeline (benchmark + grade + visualise)
Rscript run_pipeline.R

# Single backend
Rscript run_pipeline.R --backend agentic_single

# Re-plot only
Rscript run_pipeline.R --visualise-only
```

## Ground truth

Reference answer file: `~/project_ALS_databse/references/benchmarks_agentic_surf.md`

This is the updated 110-question version. Make sure this file is in place
before running `02_grade.R`.

## SURF-specific notes

- `BENCHMARKS_MD` in `config.R` points to `benchmarks_agentic_surf.md` —
  copy the updated markdown there before running grading.
- Output lands in `~/project_ALS_databse/analysis/benchmark_surf_testing/`
  and `~/project_ALS_databse/analysis/benchmark_surf_grading/`.
- `02_grade.R` still uses `ollamar` for the judge — make sure `gemma3`
  is pulled on the SURF Ollama instance.
