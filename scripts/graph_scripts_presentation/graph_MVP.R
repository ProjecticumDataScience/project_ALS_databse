library(DiagrammeR)
library(DiagrammeRsvg)
library(rsvg)

# ── DOT source ────────────────────────────────────────────────────────────────
dot <- '
digraph als_pipeline {

  graph [
    layout   = dot
    rankdir  = TB
    fontname = "Helvetica Neue"
    fontsize = 11
    ranksep  = 0.45
    nodesep  = 0.55
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
    label     = "Shiny web app  (R frontend)"
    fillcolor = "#C6E8DF"
    color     = "#0A5C47"
    fontcolor = "#0A5C47"
    penwidth  = 1.5
    width     = 2.8
  ]

  single [
    label     = "Ollama — single model\nllama3.1:8b  |  mistral"
    fillcolor = "#ECEAFB"
    color     = "#4A42B0"
    fontcolor = "#302880"
    penwidth  = 1.2
  ]

  dual_orch [
    label     = "Ollama — orchestrator\nllama3.1:8b"
    fillcolor = "#ECEAFB"
    color     = "#4A42B0"
    fontcolor = "#302880"
    penwidth  = 1.2
  ]

  sub [
    label     = "Ollama — SQL specialist\nduckdb-nsql  |  llama3.1:8b"
    fillcolor = "#F5F3FF"
    color     = "#7060C8"
    fontcolor = "#302880"
    penwidth  = 0.9
    style     = "filled,rounded,dashed"
    width     = 2.4
  ]

  mcp [
    label     = "MCP server  (Python · FastMCP)"
    fillcolor = "#FDF0DC"
    color     = "#9A6010"
    fontcolor = "#6B4200"
    penwidth  = 1.4
    width     = 3.0
  ]

  db [
    label     = "rvatData.gdb\nSQLite · varInfo_synthetic · GRCh38"
    fillcolor = "#ECEAE3"
    color     = "#7A7870"
    fontcolor = "#3C3C3A"
    shape     = cylinder
    height    = 0.7
    width     = 2.8
    penwidth  = 0.9
  ]

  answer [
    label     = "Answer + data table\ndisplayed in Shiny"
    fillcolor = "#C6E8DF"
    color     = "#0A5C47"
    fontcolor = "#0A5C47"
    penwidth  = 1.4
    width     = 2.4
  ]

  { rank = same; single; dual_orch }

  researcher -> shiny [
    label     = "types question"
    color     = "#0A5C47"
    fontcolor = "#0A5C47"
  ]
  shiny -> single [
    label     = "single LLM  "
    style     = dashed
    color     = "#1D9E75"
    fontcolor = "#1D9E75"
  ]
  shiny -> dual_orch [
    label     = "  two LLM"
    style     = dashed
    color     = "#4A42B0"
    fontcolor = "#4A42B0"
  ]
  dual_orch -> sub [
    label     = "if run_query"
    style     = dashed
    color     = "#9B88E0"
    fontcolor = "#7060C8"
  ]
  single -> mcp [
    label     = "tool call"
    color     = "#1D9E75"
    fontcolor = "#1D9E75"
  ]
  dual_orch -> mcp [
    label     = "tool call  "
    color     = "#4A42B0"
    fontcolor = "#4A42B0"
  ]
  sub -> mcp [
    label     = "refined SQL"
    color     = "#9B88E0"
    fontcolor = "#7060C8"
  ]
  mcp -> db [
    label     = "executes query"
    color     = "#9A6010"
    fontcolor = "#9A6010"
  ]
  db -> mcp [
    label     = "raw rows"
    style     = dashed
    color     = "#AAAAAA"
    fontcolor = "#888888"
  ]
  mcp -> answer [
    label     = "LLM summary"
    color     = "#0A5C47"
    fontcolor = "#0A5C47"
  ]
}
'

# ── Preview in RStudio viewer ─────────────────────────────────────────────────
grViz(dot)

# ── Export to PNG ─────────────────────────────────────────────────────────────
# export_svg captures the diagram at its natural SVG size.
# width = 1200px gives a clean, proportionate output — increase to 2400 for print.
svg_data <- export_svg(grViz(dot))

rsvg_png(
  svg   = charToRaw(svg_data),
  file  = "mvp_pipeline_diagram.png",
  width = 1200
)

message("Saved: mvp_pipeline_diagram.png  (", 
        round(file.size("mvp_pipeline_diagram.png") / 1024), " KB)")
