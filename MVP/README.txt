─────────────────────────────────────────────────────────────────────────────
Project ALS — Variant Assistant (MVP)
─────────────────────────────────────────────────────────────────────────────

A local AI-powered assistant for querying the ALS variant database.
Ask plain English questions and get answers backed by real database queries —
no SQL knowledge required.

Built with: R Shiny · Ollama (local LLM) · MCP server (Python/FastMCP)

─────────────────────────────────────────────────────────────────────────────
FOLDER CONTENTS
─────────────────────────────────────────────────────────────────────────────

  app.R                      Main Shiny application
  server.py                  MCP tool server (exposes database query endpoints)
  start_services.sh          Startup script (launches the MCP server)
  prompts.txt                Domain knowledge loaded at runtime by the LLM
  environment.yml            Conda environment definition
  rvatData.gdb               ALS variant database (SQLite)
  mvp_pipeline_diagram.png   Diagram that showcases MVP pipeline
  README.txt                 This file

─────────────────────────────────────────────────────────────────────────────
REQUIREMENTS
─────────────────────────────────────────────────────────────────────────────

  - Ollama         (https://ollama.com)
  - Conda          (miniconda or anaconda — https://docs.anaconda.com/miniconda)
  - R + RStudio    (https://posit.co/download/rstudio-desktop)

─────────────────────────────────────────────────────────────────────────────
FIRST-TIME SETUP  (do this once)
─────────────────────────────────────────────────────────────────────────────

0. Place the MVP folder in your home directory

   Move or copy the MVP folder so it lives at ~/MVP:

     Linux/macOS:  mv ~/Downloads/MVP ~/MVP
     Windows:      move it to C:\Users\YourName\MVP

   Then open a terminal and navigate to it:

     cd ~/MVP

   All subsequent commands assume you are in this folder.

1. Pull the required Ollama models

   Make sure Ollama is installed and running, then in a terminal:

     ollama pull llama3.1:8b
     ollama pull duckdb-nsql
     ollama pull mistral

   llama3.1:8b and duckdb-nsql are required for the recommended pipeline.
   mistral is optional.

2. Create the conda environment

   From inside ~/MVP, run:

     conda env create -f environment.yml

   This installs the Python dependencies for the MCP server (mcpo, fastmcp).
   Only needs to be done once.

3. Install R packages

   In R or RStudio, run:

     install.packages(c("shiny", "bslib", "DT", "httr2", "jsonlite", "shinyjs"))

─────────────────────────────────────────────────────────────────────────────
STARTUP  (do this every session)
─────────────────────────────────────────────────────────────────────────────

1. Open a terminal, navigate to the MVP folder and start the MCP server:

     cd ~/MVP
     bash start_services.sh

   Wait for the "health check ✓" message before continuing.
   The server runs in the background — keep this terminal open.

   Note: on Windows, use Git Bash or WSL to run this command.
   It will not work in Command Prompt or PowerShell.

2. Open app.R in RStudio and click Run App.

   A browser tab will open with the Variant Assistant interface.

3. Check that Status shows "● MCP connected" in green in the sidebar.
   If it shows "MCP unreachable", wait 10 seconds and run
   start_services.sh again.

─────────────────────────────────────────────────────────────────────────────
CHOOSING A PIPELINE
─────────────────────────────────────────────────────────────────────────────

Select a pipeline from the sidebar dropdown. Recommended default:

  ★ Two LLM — llama3.1 → duckdb-nsql
    The orchestrator (llama3.1:8b) interprets the question and selects
    the right database tool. The SQL specialist (duckdb-nsql) refines
    any free-form queries before execution.
    Best balance of accuracy and reliability.

Other options:

  Two LLM — llama3.1 → llama3.1
    Both steps use the same model. Slightly faster, less SQL precision.

  Single — llama3.1:8b
    One model handles everything. Good for simple lookup questions.

  Single — mistral
    Fastest. Lower reliability on complex queries.

─────────────────────────────────────────────────────────────────────────────
USING THE APP
─────────────────────────────────────────────────────────────────────────────

  - Type a question in the input box and press Enter or click →
  - Click any Example Question in the sidebar to pre-fill the input
  - The chat panel shows the answer; the Results panel shows the raw data
  - Each answer shows which database tool was used (🔧 tool name)
  - Click "Clear conversation" to start fresh

Example questions to try (with known correct answers):

  How many variants are in ABCA4?              → 589
  How many variants in SOD1 are high impact?   → 4
  How many genes are in the database?          → 12
  How many total variants are in the database? → 1802
  What is the average age of ALS patients?     → unanswerable (by design)

─────────────────────────────────────────────────────────────────────────────
TROUBLESHOOTING
─────────────────────────────────────────────────────────────────────────────

  MCP unreachable     Run start_services.sh again and wait 10 seconds.
                      Check that rvatData.gdb is in the ~/MVP folder.

  Ollama not found    Make sure Ollama is running: ollama list (in terminal)

  conda not found     Make sure miniconda/anaconda is installed and that
                      your terminal session has conda initialised.
                      Try opening a new terminal after installation.

  Wrong answers       Switch to Two LLM + duckdb-nsql pipeline.

  Response in Dutch   Known LLM behaviour — re-submit the question.

  Slow responses      Expected for Two LLM pipelines. Single LLM is faster.

─────────────────────────────────────────────────────────────────────────────
NOTES
─────────────────────────────────────────────────────────────────────────────

  - All processing is fully local. No data leaves the machine.
  - The database (rvatData.gdb) must stay in the ~/MVP folder alongside
    server.py and start_services.sh. The app will not start without it.
  - prompts.txt controls the domain knowledge available to the LLM.
    Edit it to adjust how the assistant interprets questions.
  - The assistant correctly refuses questions about patient age, sex,
    ClinVar pathogenicity, and population allele frequencies — these
    are not present in the current database schema.

─────────────────────────────────────────────────────────────────────────────