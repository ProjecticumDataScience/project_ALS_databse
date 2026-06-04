#!/bin/bash
# ─────────────────────────────────────────────────────────────
# Project ALS  —  MVP launcher
# Self-contained: expects rvatData.gdb in the same folder.
# ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_PY="$SCRIPT_DIR/server.py"

export RVAT_GDB_PATH="$SCRIPT_DIR/rvatData.gdb"
export RVAT_TABLE="varInfo_synthetic"

## ── Auto-detect conda ────────────────────────────────────────
find_conda() {
  for candidate in \
    "$HOME/miniconda3" "$HOME/anaconda3" \
    "$HOME/miniconda"  "$HOME/anaconda"  \
    "/opt/miniconda3"  "/opt/anaconda3"; do
    if [ -f "$candidate/bin/activate" ]; then echo "$candidate"; return 0; fi
  done
  command -v conda &>/dev/null && conda info --base 2>/dev/null && return 0
  return 1
}

find_mcpo_env() {
  local base="$1"
  for env in webui mcp_env mcp als_env base; do
    [ -f "$base/envs/$env/bin/mcpo" ] && echo "$env" && return 0
  done
  [ -f "$base/bin/mcpo" ] && echo "base" && return 0
  return 1
}

CONDA_BASE=$(find_conda)
if [ -z "$CONDA_BASE" ]; then
  echo "ERROR: Conda not found. Install miniconda or anaconda first."; exit 1
fi

CONDA_ENV=$(find_mcpo_env "$CONDA_BASE")
if [ -z "$CONDA_ENV" ]; then
  echo "ERROR: No conda environment with mcpo found."
  echo "  Run: conda env create -f environment.yml"; exit 1
fi

if [ "$CONDA_ENV" = "base" ]; then
  PYTHON_BIN="$CONDA_BASE/bin/python3"
  MCPO_BIN="$CONDA_BASE/bin/mcpo"
else
  PYTHON_BIN="$CONDA_BASE/envs/$CONDA_ENV/bin/python3"
  MCPO_BIN="$CONDA_BASE/envs/$CONDA_ENV/bin/mcpo"
fi

MCP_PORT="${MCP_PORT:-8005}"

echo "================================================"
echo " Project ALS — Variant Assistant MVP"
echo "================================================"
echo " User        : $USER"
echo " Conda env   : $CONDA_ENV"
echo " server.py   : $SERVER_PY"
echo " Database    : $RVAT_GDB_PATH"
echo " MCP port    : $MCP_PORT"
echo "================================================"

## ── Sanity checks ────────────────────────────────────────────
if [ ! -f "$SERVER_PY" ]; then
  echo "ERROR: server.py not found at $SERVER_PY"; exit 1
fi

if [ ! -f "$RVAT_GDB_PATH" ]; then
  echo "ERROR: rvatData.gdb not found at $RVAT_GDB_PATH"
  echo "  Make sure rvatData.gdb is in the same folder as this script."; exit 1
fi

## ── Stop existing process on port ───────────────────────────
pkill -u "$USER" -f "mcpo.*$MCP_PORT" 2>/dev/null && sleep 1 || true

## ── Start mcpo ───────────────────────────────────────────────
source "$CONDA_BASE/bin/activate" "$CONDA_ENV" 2>/dev/null || true
"$MCPO_BIN" --port "$MCP_PORT" -- "$PYTHON_BIN" "$SERVER_PY" &
MCPO_PID=$!
echo "mcpo started (pid $MCPO_PID)"

## ── Health check ─────────────────────────────────────────────
echo "Waiting for mcpo on port $MCP_PORT..."
for i in $(seq 1 20); do
  if curl -sf "http://localhost:$MCP_PORT/openapi.json" >/dev/null 2>&1; then
    echo "mcpo health check ✓  (ready after ${i}s)"
    break
  fi
  sleep 1
  [ "$i" -eq 20 ] && echo "WARNING: mcpo not responding after 20s"
done

echo ""
echo "================================================"
echo " Ready! Open app.R in RStudio and click Run App"
echo "  MCP server → http://localhost:$MCP_PORT"
echo "================================================"