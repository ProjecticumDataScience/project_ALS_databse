#!/bin/bash
# ─────────────────────────────────────────────────────────────
# Project ALS  —  MCP service launcher
# Auto-detects conda and user — no manual configuration needed
# ─────────────────────────────────────────────────────────────

## ── Paths (auto-detected) ────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_PY="$SCRIPT_DIR/server.py"
PROJECT_DIR="$HOME/project_ALS_databse"

export RVAT_GDB_PATH="$PROJECT_DIR/references/rvatData.gdb"
export RVAT_TABLE="varInfo_synthetic"

## ── Auto-detect conda installation ───────────────────────────
find_conda() {
  ## Check common locations in order of preference
  for candidate in \
    "$HOME/miniconda3" \
    "$HOME/anaconda3" \
    "$HOME/miniconda" \
    "$HOME/anaconda" \
    "/opt/miniconda3" \
    "/opt/anaconda3"; do
    if [ -f "$candidate/bin/activate" ]; then
      echo "$candidate"
      return 0
    fi
  done
  ## Try conda in PATH
  if command -v conda &> /dev/null; then
    conda info --base 2>/dev/null
    return 0
  fi
  return 1
}

## ── Auto-detect conda environment with mcpo ──────────────────
find_mcpo_env() {
  local conda_base="$1"
  ## Check common environment names
  for env_name in webui mcp_env mcp als_env base; do
    local python_bin="$conda_base/envs/$env_name/bin/python3"
    local mcpo_bin="$conda_base/envs/$env_name/bin/mcpo"
    if [ -f "$mcpo_bin" ]; then
      echo "$env_name"
      return 0
    fi
  done
  ## Check base environment
  if [ -f "$conda_base/bin/mcpo" ]; then
    echo "base"
    return 0
  fi
  return 1
}

## ── Run detection ─────────────────────────────────────────────
CONDA_BASE=$(find_conda)
if [ -z "$CONDA_BASE" ]; then
  echo "ERROR: Conda not found. Install miniconda or anaconda first."
  exit 1
fi

CONDA_ENV=$(find_mcpo_env "$CONDA_BASE")
if [ -z "$CONDA_ENV" ]; then
  echo "ERROR: No conda environment with mcpo found."
  echo "Install mcpo with: pip install mcpo"
  exit 1
fi

## Resolve correct python and mcpo binaries
if [ "$CONDA_ENV" = "base" ]; then
  PYTHON_BIN="$CONDA_BASE/bin/python3"
  MCPO_BIN="$CONDA_BASE/bin/mcpo"
else
  PYTHON_BIN="$CONDA_BASE/envs/$CONDA_ENV/bin/python3"
  MCPO_BIN="$CONDA_BASE/envs/$CONDA_ENV/bin/mcpo"
fi

## ── MCP Port ──────────────────────────────────────────────────
## Default port 8005. Override: MCP_PORT=8006 bash start_services.sh
MCP_PORT="${MCP_PORT:-8005}"

echo "================================================"
echo " Project ALS — starting MCP services"
echo "================================================"
echo " User        : $USER"
echo " Conda base  : $CONDA_BASE"
echo " Environment : $CONDA_ENV"
echo " Python      : $PYTHON_BIN"
echo " server.py   : $SERVER_PY"
echo " Database    : $RVAT_GDB_PATH"
echo " MCP port    : $MCP_PORT"
echo "================================================"

## ── Sanity checks ─────────────────────────────────────────────
if [ ! -f "$SERVER_PY" ]; then
  echo "ERROR: server.py not found at $SERVER_PY"
  exit 1
fi

if [ ! -f "$RVAT_GDB_PATH" ]; then
  echo "WARNING: database not found at $RVAT_GDB_PATH"
  echo "  Expected: $RVAT_GDB_PATH"
fi

if [ ! -f "$PYTHON_BIN" ]; then
  echo "ERROR: Python not found at $PYTHON_BIN"
  exit 1
fi

## ── Stop existing processes on the chosen port ────────────────
## Only kills processes we own (no sudo needed)
echo "Stopping any existing mcpo on port $MCP_PORT..."
pkill -u "$USER" -f "mcpo.*$MCP_PORT" 2>/dev/null && sleep 1 || true

## ── Start mcpo ───────────────────────────────────────────────
source "$CONDA_BASE/bin/activate" "$CONDA_ENV" 2>/dev/null || true
"$MCPO_BIN" --port "$MCP_PORT" -- "$PYTHON_BIN" "$SERVER_PY" &
MCPO_PID=$!
echo "mcpo started (pid $MCPO_PID)"

## ── Health check ─────────────────────────────────────────────
echo "Waiting for mcpo on port $MCP_PORT..."
for i in $(seq 1 20); do
  if curl -sf "http://localhost:$MCP_PORT/openapi.json" > /dev/null 2>&1; then
    echo "mcpo health check ✓  (ready after ${i}s)"
    break
  fi
  sleep 1
  if [ "$i" -eq 20 ]; then
    echo "WARNING: mcpo not responding after 20s"
    echo "Check: curl http://localhost:$MCP_PORT/openapi.json"
  fi
done


echo ""
echo "================================================"
echo " Services started for user: $USER"
echo "  MCP/mcpo  → http://localhost:$MCP_PORT"
echo "  Shiny app → open app.R in RStudio"
echo ""
echo " To use a different port:"
echo "  MCP_PORT=8006 bash start_services.sh"
echo "================================================"