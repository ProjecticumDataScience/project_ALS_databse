## ============================================================
## pipeline_diagram.R
## Renders pipeline diagram in RStudio Viewer.
## Run: source("pipeline_diagram.R")
## ============================================================

library(DiagrammeR)
library(DiagrammeRsvg)
library(rsvg)


graph <- grViz("
digraph pipeline {

  graph [layout = dot, rankdir = TB, fontname = 'Helvetica',
         bgcolor = '#FAFAFA', pad = 0.6, nodesep = 0.45, ranksep = 0.7]

  node [fontname = 'Helvetica', fontsize = 12, style = filled,
        shape = box, margin = '0.22,0.14', penwidth = 1.3]

  edge [fontname = 'Helvetica', fontsize = 9, color = '#888888',
        arrowsize = 0.7, penwidth = 1.1]

  ## ── Inputs ───────────────────────────────────────────────
  subgraph cluster_inputs {
    label     = 'Inputs / config'
    fontsize  = 11
    fontcolor = '#555555'
    color     = '#CCCCCC'
    style     = dashed

    config [label = 'config.R\nBACKENDS_TO_RUN · MODELS_TO_TEST\nJUDGE_MODEL · Paths',
            fillcolor = '#D6EAF8', color = '#2E86C1']

    prompts [label = 'prompts.txt\ndata_description · extra_instructions',
             fillcolor = '#D6EAF8', color = '#2E86C1']

    benchmarks [label = 'benchmarks.md\nExpected SQL + correct answers (grading key)',
                fillcolor = '#D6EAF8', color = '#2E86C1']

    gdb [label = 'rvatData.gdb\nSQLite variant database · varInfo_synthetic',
         fillcolor = '#D6EAF8', color = '#2E86C1']
  }

  ## ── Orchestrator ─────────────────────────────────────────
  runner [label = 'run_pipeline.R  —  Orchestrator · CLI flags',
          fillcolor = '#E8DAEF', color = '#7D3C98', fontsize = 12]

  ## ── Step 1 ───────────────────────────────────────────────
  bench [label = '01_benchmark.R\nFor each backend x model: ask 15 questions\ncapture SQL + response',
         fillcolor = '#D6EAF8', color = '#1A5276']

  ## ── Questions — single consolidated node ─────────────────
  questions [label = 'Benchmark questions (15 total)\nLookup (L1-L5): gene queries · impact filters · SIFT predictions\nAnalytical (A1-A5): allele frequency · burden sums · case vs control\nUnanswerable (U1-U5): age · ethnicity · pathogenicity  (model must refuse)',
             fillcolor = '#EBF5FB', color = '#2E86C1', fontsize = 10]

  ## ── Backends ─────────────────────────────────────────────
  bq [label = 'querychat\nframework + SQL tooling\nreads gdb directly',
      fillcolor = '#D5F5E3', color = '#1E8449']

  bm [label = 'mcp\nHTTP → mcpo (localhost:8000)',
      fillcolor = '#FDEBD0', color = '#CA6F1E']

  be [label = 'ellmer\nraw tool-calling · no framework\nreads gdb directly',
      fillcolor = '#FEF9E7', color = '#B7950B']

  ## ── Shared services ──────────────────────────────────────
  ollama [label = 'Ollama (localhost:11434)\nllama3.1:8b · mistral · deepseek-r1:8b · qwen3:8b · llama3.2',
          fillcolor = '#FDFEFE', color = '#555555', style = 'filled,dashed']

  mcp_server [label = 'mcp_server_setup/\nserver.py (FastMCP) · start_services.sh',
              fillcolor = '#FDFEFE', color = '#555555', style = 'filled,dashed']

  ## ── Intermediate output: combined CSV ────────────────────
  out_csv [label = 'benchmark_testing/\nall_backends_combined.csv\n(id · category · model · backend · SQL log · response)',
           fillcolor = '#F2F3F4', color = '#888888']

  ## ── Step 2 ───────────────────────────────────────────────
  grade [label = '02_grade.R\nAuto-grade with judge LLM (gemma3)\ngrade_answer · grade_hallucination\ngrade_minimal_response · grade_sql\nScore 0-4 per question · manual review of NAs',
         fillcolor = '#E8DAEF', color = '#6C3483']

  scoring [label = 'Scoring rubric\ngrade_answer          pass/fail\ngrade_hallucination      pass/fail\ngrade_minimal_response   pass/fail\ngrade_sql             pass/fail\n───────────────────\nTotal: 0-4 per question',
           fillcolor = '#F5EEF8', color = '#6C3483', fontsize = 10]

  ## ── Grading output ───────────────────────────────────────
  out_grade [label = 'benchmark_grading/grading_<datetime>/\nautograded_*.csv · finalgraded_*.csv',
             fillcolor = '#F2F3F4', color = '#888888']

  ## ── Step 3 ───────────────────────────────────────────────
  vis [label = '03_visualise.R\nAuto-discovers finalgraded_*.csv · averages across runs\nGroups + facets by backend · 5 comparison plots',
       fillcolor = '#FADBD8', color = '#922B21']

  ## ── Plot output ──────────────────────────────────────────
  out_plots [label = 'Plots (PNG)\nplot_overall_scores · plot_backend_comparison\nplot_category_scores · plot_heatmap · plot_criteria_scores',
             fillcolor = '#F2F3F4', color = '#888888']

  ## ── Edges: inputs → pipeline ─────────────────────────────
  config     -> runner [color = '#2E86C1']
  prompts    -> bench  [color = '#2E86C1']
  benchmarks -> grade  [color = '#2E86C1']
  gdb -> bq         [color = '#2E86C1', label = 'direct read']
  gdb -> be         [color = '#2E86C1', label = 'direct read']
  gdb -> mcp_server [color = '#2E86C1', label = 'served via']

  ## ── Main spine ───────────────────────────────────────────
  runner  -> bench    [color = '#7D3C98', penwidth = 1.8]
  bench   -> out_csv  [color = '#1A5276', penwidth = 1.5, label = 'writes']
  out_csv -> grade    [color = '#7D3C98', penwidth = 1.8, label = 'input to']
  grade   -> out_grade [color = '#6C3483', penwidth = 1.5, label = 'writes']
  out_grade -> vis    [color = '#7D3C98', penwidth = 1.8, label = 'input to']
  vis     -> out_plots [color = '#922B21', penwidth = 1.5, label = 'writes']

  ## ── Benchmark branches ───────────────────────────────────
  bench -> questions [color = '#2E86C1', style = dashed]
  bench -> bq        [color = '#1E8449']
  bench -> bm        [color = '#CA6F1E']
  bench -> be        [color = '#B7950B']

  ## ── Backends → shared services ───────────────────────────
  bq -> ollama     [color = '#1E8449', style = dashed, label = 'LLM calls']
  bm -> ollama     [color = '#CA6F1E', style = dashed, label = 'LLM calls']
  be -> ollama     [color = '#B7950B', style = dashed, label = 'LLM calls']
  bm -> mcp_server [color = '#CA6F1E', style = dashed, label = 'requires']

  ## ── Scoring rubric ────────────────────────────────────────
  grade -> scoring [color = '#6C3483', style = dashed, arrowhead = none]
}
")

out_file <- path.expand("~/project_ALS_databse/scripts/benchmark/pipeline_diagram/pipeline_diagram.png")

svg_str <- export_svg(graph)
rsvg_png(charToRaw(svg_str),
         file   = out_file,
         width  = 2400,
         height = 1800)

cat("Diagram saved to:", out_file, "\n")
