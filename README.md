# Project MinE ALS — Variant Database Assistant

An LLM-powered natural-language assistant for querying the Project MinE ALS
genomic variant database (`rvatData.gdb`). Ask a question in plain English —
how many variants in a gene, which samples carry a high-impact mutation,
whether a gene shows statistical burden enrichment in ALS cases versus
controls — and the assistant routes it to the right database tool, writes
and validates SQL where needed, and answers with the actual result.

**Start here: [`final_app/`](final_app/)** — the finished, presentation-ready
version of this project. Everything else in this repository is iteration
history kept for reference (benchmark results, earlier architecture
experiments, the original MVP). If you just want to run the assistant,
read `final_app/README.md` and ignore the rest of this document.

---

## Repository layout

```
project_ALS_databse/
├── final_app/              ← THE finished app — start here
├── MVP/                    ← Original minimum viable product (single LLM, single tool)
├── scripts/
│   ├── agentic/             ← Posit/RStudio version of the agentic pipeline
│   ├── agentic_surf/        ← SURF HPC version — final_app/ was built from this
│   ├── benchmark/            ← Benchmark harness for the original (non-agentic) pipeline
│   ├── benchmark_agentic/    ← Benchmark harness for the agentic pipeline (posit)
│   ├── benchmark_multi/      ← Benchmark harness for multi-model comparisons
│   ├── benchmark_surf/       ← Benchmark harness used for all final tuning/grading on SURF
│   ├── create_varInfo_synthetic.R   ← Generates the synthetic 10-sample genotype table
│   └── graph_scripts_presentation/  ← One-off plotting scripts used in presentation decks
├── references/              ← Ground-truth answer keys for every benchmark question set,
│                                plus a copy of rvatData.gdb
├── analysis/                ← Every benchmark run's raw output, grading, and plots
│                                (see "How benchmarking works" below)
├── presentations/           ← Slide decks and write-ups
└── project_ALS_databse.Rproj
```

---

## Project history, briefly

This project went through several rounds of architecture before settling on
the version in `final_app/`:

1. **`MVP/`** — a single-LLM, single-tool proof of concept: one Ollama model,
   one Python MCP server, no routing or multi-step reasoning.
2. **`scripts/agentic/`** — introduced the agentic architecture (multi-step
   tool calling, multiple specialised MCP servers) on a local/Posit setup.
3. **`scripts/agentic_surf/`** — ported the agentic pipeline to SURF HPC
   (this server), where the actual model (`llama3.1:70b`) could run at
   usable speed. Most of the architecture work — the decompose/route/
   generate-SQL/validate/self-correct pipeline, the rvat statistical
   bridge, and the final set of MCP tools — was built and tuned here.
4. **`final_app/`** — the consolidated, cleaned-up result. Earlier versions
   explored single-model, two-model, and adaptive multi-model
   configurations; 111-question benchmarking (see `references/benchmarks_agentic_surf.md`
   for the ground-truth answer key) showed the single-model architecture
   matched or beat every multi-model variant while running faster, so
   `final_app/` keeps only that.

If you want to see *why* particular design decisions were made — why a
question type gets a dedicated tool instead of free-form SQL, why certain
genomics conventions ("pathogenic" = high+moderate impact, "deleterious"
PolyPhen = `'D'` only) are hardcoded the way they are — the answer is
almost always "a specific benchmark question exposed a failure, and this
was the fix." `references/benchmarks_agentic_surf.md` documents the
intended answer and reasoning for every one of the 111 test questions.

---

## How benchmarking works

`scripts/benchmark_surf/` is the benchmark harness used for all final
tuning:

- **`01_benchmark.R`** — runs all 111 questions through the pipeline and
  saves raw responses
- **`02_grade.R`** — an LLM grader scores each response against the answer
  key in `references/benchmarks_agentic_surf.md` on four criteria: answer
  correctness, conciseness, hallucination-freedom, and correct tool use
- **`03_visualise.R`** — produces comparison plots (overall scores,
  per-category breakdowns, response time, and a phase-by-phase timing
  breakdown showing where time is spent within a single question)

Results live in `analysis/`:
- `analysis/benchmark_surf_testing/` — raw output from each benchmark run
  (timestamped folders)
- `analysis/benchmark_surf_grading/` — graded CSVs and plots for each run
- `analysis/benchmark_agentic_grading/` — earlier grading runs from the
  posit/agentic version, kept for historical comparison

If you want to re-run the benchmark against `final_app/`'s pipeline, copy
`scripts/benchmark_surf/`'s harness and point its `config.R` at
`final_app/pipeline.R` instead of `scripts/agentic_surf/pipeline.R`.

---

## The dataset

`rvatData.gdb` (a SQLite-based rvat genomic database) appears in three
places in this repo (`MVP/`, `references/`, and copied into whichever
pipeline folder needs it at runtime) — they should be identical copies of
the same file. See `final_app/README.md` for full schema documentation.

In brief: `varInfo_synthetic` holds 1,802 variants across 12 ALS-associated
genes with a synthetic 10-sample genotype subset (5 cases, 5 controls) for
fast variant-level queries; `pheno` holds the full 25,000-sample cohort
used for population/sex/age-filtered questions and real statistical
analysis via the rvat R package.

---

## License

See [`LICENSE`](LICENSE).