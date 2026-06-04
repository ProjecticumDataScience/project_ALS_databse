#!/bin/bash
# ─────────────────────────────────────────────────────────────
# Project ALS  —  MCP service launcher
# ─────────────────────────────────────────────────────────────
#
# CONFIGURE THIS SECTION if paths differ on your machine:
# ─────────────────────────────────────────────────────────────

## The conda user whose environment contains mcpo + open-webui.
## Defaults to the current logged-in user ($USER).
## Override here if the conda env lives under a different user:
CONDA_USER="robin.jansen"

## Conda environment name that has mcpo and open-webui installed
CONDA_ENV="webui"

## Root of the project
PROJECT_DIR="$HOME/project_ALS_databse"

## Conda base directory
CONDA_BASE="/home/${CONDA_USER}/miniconda3"

# ─────────────────────────────────────────────────────────────
# Derived paths — no need to edit below this line
# ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_PY="$SCRIPT_DIR/server.py"
PYTHON_BIN="$CONDA_BASE/envs/${CONDA_ENV}/bin/python3"

export RVAT_GDB_PATH="$PROJECT_DIR/rvatData.gdb"
export RVAT_TABLE="varInfo_synthetic"

echo "================================================"
echo " Project ALS — starting MCP services"
echo "================================================"
echo " Conda user  : $CONDA_USER"
echo " Python      : $PYTHON_BIN"
echo " Project dir : $PROJECT_DIR"
echo " server.py   : $SERVER_PY"
echo " Database    : $RVAT_GDB_PATH"
echo "================================================"

# ── Sanity checks ────────────────────────────────────────────
if [ ! -f "$SERVER_PY" ]; then
  echo "ERROR: server.py not found at $SERVER_PY"
  exit 1
fi

if [ ! -f "$RVAT_GDB_PATH" ]; then
  echo "WARNING: database not found at $RVAT_GDB_PATH"
  echo "  Set PROJECT_DIR correctly at the top of this script."
fi

if [ ! -f "$CONDA_BASE/bin/activate" ]; then
  echo "ERROR: conda not found at $CONDA_BASE"
  echo "  Set CONDA_USER at the top of this script."
  exit 1
fi

if [ ! -f "$PYTHON_BIN" ]; then
  echo "ERROR: Python not found at $PYTHON_BIN"
  echo "  Check CONDA_ENV and CONDA_USER at the top of this script."
  exit 1
fi

# ── Kill any leftover processes ──────────────────────────────
# Note: skipping pkill since existing processes may be owned by another user
echo "Skipping cleanup — existing mcpo on port 8000 may be owned by another user"

# ── 1. Open WebUI ────────────────────────────────────────────
source "$CONDA_BASE/bin/activate" "$CONDA_ENV"
open-webui serve &
WEBUI_PID=$!
echo "Open WebUI started (pid $WEBUI_PID)"
conda deactivate 2>/dev/null || true

# ── 2. mcpo + MCP server ────────────────────────────────────
source "$CONDA_BASE/bin/activate" "$CONDA_ENV"
mcpo --port 8002 -- "$PYTHON_BIN" "$SERVER_PY" &
MCPO_PID=$!
echo "mcpo started (pid $MCPO_PID)"
echo "  → wrapping: $SERVER_PY"

# ── 3. Health check ─────────────────────────────────────────
echo "Waiting for mcpo..."
for i in $(seq 1 15); do
  if curl -sf http://localhost:8002/openapi.json > /dev/null 2>&1; then
    echo "mcpo health check ✓  (ready after ${i}s) — port 8001"
    break
  fi
  sleep 1
  if [ "$i" -eq 15 ]; then
    echo "WARNING: mcpo not responding after 15s — check logs above."
  fi
done

echo ""
echo "================================================"
echo " All services started"
echo "  Open WebUI → http://localhost:8080"
echo "  MCP/mcpo   → http://localhost:8002"
echo "  Benchmark  → Rscript run_pipeline.R --backend mcp  (MCP_URL = http://localhost:8002)"
echo "================================================"