#!/bin/bash
# ─────────────────────────────────────────────────────────────
# Project ALS — Agentic pipeline launcher
# Starts mcpo with 4 MCP servers via servers.json config
# ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVERS_JSON="$SCRIPT_DIR/servers.json"

## Database: check local agentic/ folder first, then project references
if [ -f "$SCRIPT_DIR/rvatData.gdb" ]; then
  export RVAT_GDB_PATH="$SCRIPT_DIR/rvatData.gdb"
elif [ -f "$HOME/project_ALS_databse/references/rvatData.gdb" ]; then
  export RVAT_GDB_PATH="$HOME/project_ALS_databse/references/rvatData.gdb"
else
  echo "ERROR: rvatData.gdb not found."
  echo "  Copy it to $SCRIPT_DIR/ or set RVAT_GDB_PATH manually."
  exit 1
fi

## ── Auto-detect conda ────────────────────────────────────────
find_conda() {
  for candidate in \
    "$HOME/miniconda3" "$HOME/anaconda3" \
    "$HOME/miniconda"  "$HOME/anaconda"  \
    "/opt/miniconda3"  "/opt/anaconda3"; do
    [ -f "$candidate/bin/activate" ] && echo "$candidate" && return 0
  done
  command -v conda &>/dev/null && conda info --base 2>/dev/null && return 0
  return 1
}

find_mcpo_env() {
  local base="$1"
  for env in mcp_env mcp als_env webui base; do
    [ -f "$base/envs/$env/bin/mcpo" ] && echo "$env" && return 0
  done
  [ -f "$base/bin/mcpo" ] && echo "base" && return 0
  return 1
}

CONDA_BASE=$(find_conda)
[ -z "$CONDA_BASE" ] && echo "ERROR: Conda not found." && exit 1

CONDA_ENV=$(find_mcpo_env "$CONDA_BASE")
[ -z "$CONDA_ENV" ] && echo "ERROR: No conda env with mcpo found. Run: conda env create -f environment.yml" && exit 1

if [ "$CONDA_ENV" = "base" ]; then
  MCPO_BIN="$CONDA_BASE/bin/mcpo"
else
  MCPO_BIN="$CONDA_BASE/envs/$CONDA_ENV/bin/mcpo"
fi

MCP_PORT="${MCP_PORT:-8007}"

echo "================================================"
echo " Project ALS — Agentic Pipeline"
echo "================================================"
echo " User        : $USER"
echo " Conda env   : $CONDA_ENV"
echo " servers.json: $SERVERS_JSON"
echo " Database    : $RVAT_GDB_PATH"
echo " MCP port    : $MCP_PORT"
echo "================================================"

if [ ! -f "$SERVERS_JSON" ]; then
  echo "ERROR: servers.json not found at $SERVERS_JSON"; exit 1
fi

## Stop existing process on port
pkill -u "$USER" -f "mcpo.*$MCP_PORT" 2>/dev/null && sleep 1 || true

## Start mcpo with multi-server config
source "$CONDA_BASE/bin/activate" "$CONDA_ENV" 2>/dev/null || true
cd "$SCRIPT_DIR"
"$MCPO_BIN" --port "$MCP_PORT" --config "$SERVERS_JSON" &
MCPO_PID=$!
echo "mcpo started (pid $MCPO_PID)"

## Health check
echo "Waiting for mcpo on port $MCP_PORT..."
for i in $(seq 1 25); do
  if curl -sf "http://localhost:$MCP_PORT/openapi.json" >/dev/null 2>&1; then
    echo "mcpo health check ✓  (ready after ${i}s)"
    break
  fi
  sleep 1
  [ "$i" -eq 25 ] && echo "WARNING: mcpo not responding after 25s"
done

## List registered tools
echo ""
echo "Registered tools:"
curl -s "http://localhost:$MCP_PORT/openapi.json" 2>/dev/null | \
  python3 -c "import json,sys; d=json.load(sys.stdin); [print('  /', p) for p in d.get('paths',{}).keys()]" \
  2>/dev/null || echo "  (could not list tools)"

echo ""
echo "================================================"
echo " Ready!"
echo "  MCP server → http://localhost:$MCP_PORT"
echo "  Docs       → http://localhost:$MCP_PORT/docs"
echo "================================================"
REOF