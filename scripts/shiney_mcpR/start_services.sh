#!/bin/bash

PROJECT_DIR="$HOME/project_ALS_databse"
SCRIPT_DIR="$PROJECT_DIR/scripts/shiney_mcpR"

SERVER_R="$SCRIPT_DIR/server.R"
APP_R="$SCRIPT_DIR/app.R"

CONDA_BASE="$HOME/miniconda3"

export RVAT_GDB_PATH="$PROJECT_DIR/rvatData.sqlite"

echo "======================================"
echo "Starting ALS services"
echo "======================================"

# ─────────────────────────────────────
# Kill oude processen
# ─────────────────────────────────────

pkill -f "Rscript.*server.R" 2>/dev/null || true
pkill -f "shiny::runApp"     2>/dev/null || true
sleep 2

# ─────────────────────────────────────
# Start DBI API server
# ─────────────────────────────────────

Rscript "$SERVER_R" &
SERVER_PID=$!

echo "DBI API gestart (pid $SERVER_PID)"

sleep 3

# ─────────────────────────────────────
# Start Shiny app
# ─────────────────────────────────────

R -e "shiny::runApp('$APP_R', host='0.0.0.0', port=8080)" &
SHINY_PID=$!

echo "Shiny gestart (pid $SHINY_PID)"

echo ""
echo "======================================"
echo " Shiny : http://localhost:8080"
echo " API   : http://localhost:8000"
echo "======================================"