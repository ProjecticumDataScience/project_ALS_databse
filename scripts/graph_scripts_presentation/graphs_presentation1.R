library(DiagrammeR)
library(DiagrammeRsvg)
library(rsvg)

# ── 1. Current querychat pipeline ────────────────────────────────────────────
p1 <- grViz("
digraph current_pipeline {
  graph [layout = dot, rankdir = LR, fontname = 'Helvetica']
  node [fontname = 'Helvetica', fontsize = 12, style = filled, shape = roundedbox]
  
  User    [label = 'Researcher\\n(plain English)', fillcolor = '#E8F4FD', color = '#457B9D']
  LLM     [label = 'Ollama\\n(local LLM)',         fillcolor = '#E1D5E7', color = '#9B5DE5']
  QC      [label = 'querychat\\n(NL → SQL)',        fillcolor = '#FFF2CC', color = '#E9C46A']
  DB      [label = 'GDB Database\\n(SQLite)',        fillcolor = '#FFE6CC', color = '#F4A261']
  Answer  [label = 'Answer\\nto researcher',         fillcolor = '#D5E8D4', color = '#2A9D8F']

  User   -> LLM    [label = 'question']
  LLM    -> QC     [label = 'generates SQL']
  QC     -> DB     [label = 'executes query']
  DB     -> LLM    [label = 'results']
  LLM    -> Answer [label = 'summarises']
}
")

# ── 2. MCP agent (simple) ─────────────────────────────────────────────────────
p2 <- grViz("
digraph mcp_agent {
  graph [layout = dot, rankdir = TB, fontname = 'Helvetica']
  node [fontname = 'Helvetica', fontsize = 12, style = filled, shape = roundedbox]

  User   [label = 'User question',                  fillcolor = '#E8F4FD', color = '#457B9D']
  LLM    [label = 'Ollama (Llama 3.1)',              fillcolor = '#E1D5E7', color = '#9B5DE5']
  MCP    [label = 'MCP Agent (Python)',              fillcolor = '#FFF2CC', color = '#E9C46A']
  SQL    [label = 'Tool: VCF / SQL database',        fillcolor = '#FFE6CC', color = '#F4A261']
  RVAT   [label = 'Tool: RVAT rare variant analysis',fillcolor = '#FFE6CC', color = '#F4A261']
  Pheno  [label = 'Tool: Phenotype / metadata',      fillcolor = '#FFE6CC', color = '#F4A261']
  Answer [label = 'Answer to researcher',            fillcolor = '#D5E8D4', color = '#2A9D8F']

  User -> LLM  [label = 'question']
  LLM  -> MCP  [label = 'decides tool calls']
  MCP  -> SQL
  MCP  -> RVAT
  MCP  -> Pheno
  SQL  -> LLM  [label = 'results']
  RVAT -> LLM
  Pheno -> LLM
  LLM  -> Answer [label = 'synthesises']

  { rank = same; SQL; RVAT; Pheno }
}
")

# ── 3. Full production architecture ──────────────────────────────────────────
p3 <- grViz("
digraph MCP_pipeline {
  graph [layout = dot, rankdir = TB, fontname = 'Helvetica']
  node [fontname = 'Helvetica', fontsize = 12, style = filled, shape = roundedbox]

  User   [label = 'Researcher\\n(plain English question)',      fillcolor = '#E8F4FD', color = '#457B9D']
  Shiny  [label = 'Shiny Web App\\n(R frontend)',               fillcolor = '#D5E8D4', color = '#2A9D8F']
  MCP    [label = 'MCP Agent\\n(Python orchestrator)',          fillcolor = '#FFF2CC', color = '#E9C46A']
  LLM    [label = 'Ollama — Llama 3.1\\n(local LLM)',          fillcolor = '#E1D5E7', color = '#9B5DE5']
  SQL    [label = 'Tool: VCF / SQL DB\\nvariant queries',       fillcolor = '#FFE6CC', color = '#F4A261']
  RVAT   [label = 'Tool: RVAT (R)\\nrare variant analysis',    fillcolor = '#FFE6CC', color = '#F4A261']
  META   [label = 'Tool: Phenotype / metadata\\ncohort information', fillcolor = '#FFE6CC', color = '#F4A261']
  Synth  [label = 'Result synthesis\\n(Llama 3.1)',             fillcolor = '#E1D5E7', color = '#9B5DE5']
  Answer [label = 'Answer + data table\\ndisplayed in Shiny',  fillcolor = '#D5E8D4', color = '#2A9D8F']

  User   -> Shiny  [label = 'types question',     color = '#457B9D']
  Shiny  -> MCP    [label = 'HTTP request',        color = '#2A9D8F']
  MCP    -> LLM    [label = 'interprets intent',   color = '#9B5DE5']
  LLM    -> MCP    [label = 'decides tool calls',  color = '#9B5DE5']
  MCP    -> SQL    [color = '#F4A261']
  MCP    -> RVAT   [color = '#F4A261']
  MCP    -> META   [color = '#F4A261']
  SQL    -> Synth  [color = '#F4A261']
  RVAT   -> Synth  [color = '#F4A261']
  META   -> Synth  [color = '#F4A261']
  Synth  -> Shiny  [label = 'synthesized answer', color = '#2A9D8F']
  Shiny  -> Answer [label = 'renders response',   color = '#2A9D8F']
  Answer -> User   [color = '#457B9D']

  { rank = same; SQL; RVAT; META }
}
")

# ── Export to PNG ─────────────────────────────────────────────────────────────
diagrams <- list(
  p1 = "diagram_querychat_pipeline.png",
  p2 = "diagram_mcp_agent.png",
  p3 = "diagram_mcp_full_production.png"
)

for (name in names(diagrams)) {
  rsvg_png(
    svg  = charToRaw(export_svg(get(name))),
    file = diagrams[[name]],
    width = 1400
  )
  message("Saved: ", diagrams[[name]])
}