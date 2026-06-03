─────────────────────────────────────────────────────────────────────────────
Project ALS — Variant Assistant (MVP)
─────────────────────────────────────────────────────────────────────────────

A local AI-powered assistant for querying the ALS variant database.
Ask plain English questions and get answers backed by real database queries —
no SQL knowledge required.

Built with: R Shiny · Ollama (local LLM) · MCP server (Python/FastAPI) · DuckDB-NSQL


─────────────────────────────────────────────────────────────────────────────
PROJECT STRUCTURE
─────────────────────────────────────────────────────────────────────────────

  app.R               Main Shiny application
  server.py           MCP tool server (exposes database query endpoints)
  start_services.sh   Startup script (launches Ollama + MCP server)
  prompts.txt         Domain knowledge loaded at runtime by the LLM
  environment.yml     Conda environment definition
  README.txt          This file


─────────────────────────────────────────────────────────────────────────────
FIRST-TIME SETUP  (do this once)
─────────────────────────────────────────────────────────────────────────────

1. Pull the required Ollama models

   Open a terminal and run:

     ollama pull llama3.1:8b
     ollama pull mistral
     ollama pull duckdb-nsql

   These are the models available in the pipeline switcher.
   llama3.1:8b and duckdb-nsql are required for the recommended
   Two LLM pipeline; others are optional.

2. Create the conda environment

     conda env create -f environment.yml

   This installs Python dependencies for the MCP server (server.py).

3. Verify your project folder name
 
   The startup script expects your project to live at:
 
     ~/project_ALS_databse/
 
   If your folder is named differently, open start_services.sh and
   update line 10:
 
     PROJECT_DIR="$HOME/your_actual_folder_name"
 
   If the folder name matches, no changes are needed.


─────────────────────────────────────────────────────────────────────────────
STARTUP  (do this every session)
─────────────────────────────────────────────────────────────────────────────

1. In a terminal, run:

     bash start_services.sh

   This starts the Ollama model server and the MCP query server in the
   background. Wait a few seconds for both to initialise.

2. Open app.R in RStudio and click Run App, or run:

     Rscript app.R

   A browser tab will open with the Variant Assistant interface.

3. In the sidebar, check that Status shows "MCP connected" in green.
   If it shows "MCP unreachable", wait 10 seconds and run
   start_services.sh again.


─────────────────────────────────────────────────────────────────────────────
CHOOSING A PIPELINE
─────────────────────────────────────────────────────────────────────────────

The app supports four LLM pipeline configurations, selectable from the
sidebar under Pipeline. The recommended default is:

  ★ Two LLM — llama3.1 + llama3.1
    The orchestrator classifies the question and selects the right database
    tool; a second model pass refines any free-form SQL before execution.
    Best balance of speed and answer accuracy.

Other options:

  Two LLM — llama3.1 + duckdb-nsql
    Highest SQL accuracy. Slower. Best for complex or ambiguous queries.

  Single — llama3.1:8b
    Faster. Good tool selection, weaker on free-form SQL queries.

  Single — mistral
    Fastest responses. Lower reliability on tool selection.

Each answer shows which tool was called and a confidence indicator:
  ✔ named tool    — low risk, predefined query
  ⚠ free SQL      — higher risk, verify the result
  ✘ unanswerable  — the database does not contain this information


─────────────────────────────────────────────────────────────────────────────
EXPORTING RESULTS
─────────────────────────────────────────────────────────────────────────────

Click "Export session" at the bottom of the sidebar to download the current
session. Choose from:

  Format:   Plain text (.txt) · CSV (.csv) · HTML report (.html)
  Content:  Chat log · Results table · or both

The filename is timestamped automatically (e.g. als_session_20250604_143201.txt).


─────────────────────────────────────────────────────────────────────────────
TROUBLESHOOTING
─────────────────────────────────────────────────────────────────────────────

  MCP unreachable       Run start_services.sh again and wait 10 seconds.
  Ollama not reachable  Check that Ollama is running: ollama list (in terminal)
  Wrong answers         Switch to the Two LLM + duckdb-nsql pipeline.
  Free SQL warning      Verify the result manually; the query was AI-generated.
  Slow responses        Expected for Two LLM pipelines; Single is faster.


─────────────────────────────────────────────────────────────────────────────
NOTES
─────────────────────────────────────────────────────────────────────────────

- All processing is local. No data leaves your machine.
- The database contains synthetic ALS variant data for MVP testing.
- prompts.txt controls what domain knowledge the LLM has access to.
  Edit it to adjust how the assistant interprets questions, if deemed necessary.
- The assistant cannot answer questions about patient age, sex, ClinVar
  annotations, or population allele frequencies — these are not in the
  current database schema.

─────────────────────────────────────────────────────────────────────────────
