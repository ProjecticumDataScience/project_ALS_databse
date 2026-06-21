# ══════════════════════════════════════════════════════════════════════════════
# architecture_diagram.R — final_app pipeline architecture diagram
#
# Reflects the actual current architecture as of the final benchmark run
# (single model throughout, decompose → route → generate SQL → validate →
# self-correct, 6 MCP servers including the rvat plumber bridge). This
# replaces the earlier single/dual/sub-model diagram, which is now outdated.
#
# Run on a machine with R + DiagrammeR/DiagrammeRsvg/rsvg installed
# (the SURF server already has these for the rvat workflow).
# ══════════════════════════════════════════════════════════════════════════════
library(DiagrammeR)
library(DiagrammeRsvg)
library(rsvg)

dot <- '
digraph als_pipeline {

  graph [
    layout   = dot
    rankdir  = TB
    fontname = "Helvetica Neue"
    fontsize = 11
    ranksep  = 0.45
    nodesep  = 0.5
    splines  = polyline
    bgcolor  = "white"
    pad      = 0.4
  ]

  node [
    fontname = "Helvetica Neue"
    fontsize = 11
    style    = "filled,rounded"
    shape    = box
    penwidth = 1.1
    margin   = "0.22,0.13"
    width    = 2.4
  ]

  edge [
    fontname  = "Helvetica Neue"
    fontsize  = 9
    penwidth  = 1.0
    arrowsize = 0.7
    color     = "#888888"
    fontcolor = "#555555"
  ]

  researcher [
    label     = "Researcher"
    fillcolor = "#C6E8DF"
    color     = "#0A5C47"
    fontcolor = "#0A5C47"
    fontsize  = 12
    penwidth  = 1.5
    width     = 2.0
  ]

  shiny [
    label     = "final_app.R  (Shiny frontend)"
    fillcolor = "#C6E8DF"
    color     = "#0A5C47"
    fontcolor = "#0A5C47"
    penwidth  = 1.5
    width     = 2.8
  ]

  gate [
    label     = "Nonsense / unanswerable gate\n(no LLM call if caught here)"
    fillcolor = "#FBE3E3"
    color     = "#A23B3B"
    fontcolor = "#7A2424"
    penwidth  = 1.0
    width     = 3.0
  ]

  classify [
    label     = "classify_complexity()\nsimple  vs  complex"
    fillcolor = "#ECEAFB"
    color     = "#4A42B0"
    fontcolor = "#302880"
    penwidth  = 1.2
  ]

  decompose [
    label     = "decompose_question()\n(only if needed — skipped for\nsimple single-fact questions)"
    fillcolor = "#ECEAFB"
    color     = "#4A42B0"
    fontcolor = "#302880"
    penwidth  = 0.9
    style     = "filled,rounded,dashed"
  ]

  route [
    label     = "route_question()\npicks server + tool"
    fillcolor = "#ECEAFB"
    color     = "#4A42B0"
    fontcolor = "#302880"
    penwidth  = 1.2
  ]

  sqlgen [
    label     = "generate_sql() + validate_sql()\n(only for run_variant_query /\nrun_phenotype_query)"
    fillcolor = "#F5F3FF"
    color     = "#7060C8"
    fontcolor = "#302880"
    penwidth  = 0.9
    style     = "filled,rounded,dashed"
    width     = 2.8
  ]

  agentic [
    label     = "run_agentic_pipeline()\nmulti-step loop, max 5 steps\n(complex questions only)"
    fillcolor = "#FFF3CD"
    color     = "#8A6D1A"
    fontcolor = "#5C4A10"
    penwidth  = 1.0
    style     = "filled,rounded,dashed"
    width     = 3.0
  ]

  mcpo [
    label     = "mcpo  (MCP \u2192 HTTP proxy)"
    fillcolor = "#FDF0DC"
    color     = "#9A6010"
    fontcolor = "#6B4200"
    penwidth  = 1.4
    width     = 3.0
  ]

  tools [
    label     = "6 MCP servers\ndb_exploration \u00b7 variant_analysis\ngenotype_analysis \u00b7 phenotype_data\nclinvar_annotation \u00b7 rvat_analysis"
    fillcolor = "#FDF0DC"
    color     = "#9A6010"
    fontcolor = "#6B4200"
    penwidth  = 1.2
    width     = 3.2
  ]

  selfcorrect [
    label     = "self-correct on SQL error\n(feeds real error back, one retry)"
    fillcolor = "#FBE3E3"
    color     = "#A23B3B"
    fontcolor = "#7A2424"
    penwidth  = 0.9
    style     = "filled,rounded,dashed"
    width     = 3.0
  ]

  rvat [
    label     = "rvat plumber server  (R, port 8009)\nburden tests \u00b7 MAF \u00b7 LD \u00b7 carrier counts"
    fillcolor = "#E3EEFB"
    color     = "#2A5C9A"
    fontcolor = "#1A3C6B"
    penwidth  = 1.0
    width     = 3.2
  ]

  db [
    label     = "rvatData.gdb\nSQLite \u00b7 varInfo_synthetic (1802 var)\npheno (25,000 samples) \u00b7 GRCh38"
    fillcolor = "#ECEAE3"
    color     = "#7A7870"
    fontcolor = "#3C3C3A"
    shape     = cylinder
    height    = 0.8
    width     = 3.0
    penwidth  = 0.9
  ]

  summarize [
    label     = "summarize_result()\nllama3.1:70b, 1-sentence answer"
    fillcolor = "#C6E8DF"
    color     = "#0A5C47"
    fontcolor = "#0A5C47"
    penwidth  = 1.2
  ]

  answer [
    label     = "Answer + data table\ndisplayed in Shiny"
    fillcolor = "#C6E8DF"
    color     = "#0A5C47"
    fontcolor = "#0A5C47"
    penwidth  = 1.4
    width     = 2.6
  ]

  { rank = same; decompose; route }
  { rank = same; sqlgen; agentic }
  { rank = same; mcpo; selfcorrect }
  { rank = same; tools; rvat }

  researcher -> shiny       [label = "types question", color = "#0A5C47", fontcolor = "#0A5C47"]
  shiny -> gate             [label = "  ", color = "#0A5C47"]
  gate -> classify          [label = "passes gate", color = "#A23B3B", fontcolor = "#A23B3B"]
  gate -> answer            [label = "caught \u2014 instant reply", style = dashed, color = "#A23B3B", fontcolor = "#A23B3B"]

  classify -> decompose     [label = "simple", color = "#4A42B0", fontcolor = "#4A42B0"]
  classify -> agentic       [label = "complex", color = "#8A6D1A", fontcolor = "#8A6D1A"]

  decompose -> route        [color = "#4A42B0"]
  route -> sqlgen           [label = "if SQL tool", style = dashed, color = "#7060C8", fontcolor = "#7060C8"]
  route -> mcpo             [label = "direct tool call", color = "#4A42B0", fontcolor = "#4A42B0"]
  sqlgen -> mcpo            [label = "validated SQL", color = "#7060C8", fontcolor = "#7060C8"]

  agentic -> mcpo           [label = "tool call per step", color = "#8A6D1A", fontcolor = "#8A6D1A"]

  mcpo -> tools             [label = "HTTP", color = "#9A6010"]
  tools -> rvat             [label = "rvat_analysis only", style = dashed, color = "#2A5C9A", fontcolor = "#2A5C9A"]
  tools -> db               [label = "executes query", color = "#9A6010", fontcolor = "#9A6010"]
  rvat -> db                [label = "genotype matrix", color = "#2A5C9A", fontcolor = "#2A5C9A"]
  db -> tools               [label = "raw rows", style = dashed, color = "#AAAAAA"]

  tools -> selfcorrect      [label = "on SQL error", style = dashed, color = "#A23B3B", fontcolor = "#A23B3B"]
  selfcorrect -> tools      [label = "retry", style = dashed, color = "#A23B3B", fontcolor = "#A23B3B"]

  tools -> summarize        [label = "result JSON", color = "#0A5C47", fontcolor = "#0A5C47"]
  summarize -> answer       [color = "#0A5C47"]
}
'

grViz(dot)

svg_data <- export_svg(grViz(dot))
rsvg_png(svg = charToRaw(svg_data), file = "architecture_diagram.png", width = 1400)

message("Saved: architecture_diagram.png  (",
        round(file.size("architecture_diagram.png") / 1024), " KB)")