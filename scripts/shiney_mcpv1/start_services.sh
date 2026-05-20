#!/bin/bash
# ─────────────────────────────────────────────────────
# Project ALS  —  service launcher
# ─────────────────────────────────────────────────────

# Correct paths based on actual directory structure
PROJECT_DIR="$HOME/project_ALS_databse"
SCRIPT_DIR="$PROJECT_DIR/scripts/shiney_mcpv1"
SERVER_PY="$SCRIPT_DIR/server.py"
CONDA_BASE="$HOME/miniconda3"

export RVAT_GDB_PATH="$PROJECT_DIR/rvatData.gdb"
export RVAT_TABLE="varInfo_synthetic"

echo "================================================"
echo " Project ALS — starting services"
echo "================================================"
echo " Project dir : $PROJECT_DIR"
echo " server.py   : $SERVER_PY"
echo " Database    : $RVAT_GDB_PATH"
echo "================================================"

# ── Sanity checks ──────────────────────────────────
if [ ! -f "$SERVER_PY" ]; then
  echo "ERROR: server.py not found at $SERVER_PY"
  exit 1
fi

if [ ! -f "$RVAT_GDB_PATH" ]; then
  echo "WARNING: database not found at $RVAT_GDB_PATH"
  echo "  Set RVAT_GDB_PATH to the correct path."
fi

if [ ! -f "$CONDA_BASE/bin/activate" ]; then
  echo "ERROR: conda not found at $CONDA_BASE"
  exit 1
fi

# ── Kill any leftover processes ────────────────────
echo "Cleaning up old processes..."
pkill -f "open-webui" 2>/dev/null && echo "  Stopped old Open WebUI" || true
pkill -f "mcpo"       2>/dev/null && echo "  Stopped old mcpo"       || true
sleep 2

# ── 1. Open WebUI ──────────────────────────────────
source "$CONDA_BASE/bin/activate" webui
open-webui serve &
WEBUI_PID=$!
echo "Open WebUI started (pid $WEBUI_PID)"
conda deactivate 2>/dev/null || true

# ── 2. mcpo + MCP server ───────────────────────────
source "$CONDA_BASE/bin/activate" webui
mcpo --port 8000 -- /home/luuk.engels/miniconda3/envs/webui/bin/python3 "$SERVER_PY" &
MCPO_PID=$!
echo "mcpo started (pid $MCPO_PID)"
echo "  → wrapping: $SERVER_PY"

# ── 3. Health check ────────────────────────────────
echo "Waiting for mcpo..."
for i in $(seq 1 15); do
  if curl -sf http://localhost:8000/openapi.json > /dev/null 2>&1; then
    echo "mcpo health check ✓  (ready after ${i}s)"
    break
  fi
  sleep 1
  if [ "$i" -eq 15 ]; then
    echo "WARNING: mcpo not responding after 15s"
    echo "Check logs above for errors."
  fi
done

echo ""
echo "================================================"
echo " All services started"
echo "  Open WebUI → http://localhost:8080"
echo "  MCP/mcpo   → http://localhost:8000"
echo "  Shiny app  → open app.R in RStudio"
echo "================================================"