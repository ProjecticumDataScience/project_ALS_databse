#!/bin/bash
# ─────────────────────────────────────────────────────────────
# Project ALS — final_app launcher
# Starts the rvat plumber server + mcpo (6 MCP servers) via servers.json
# ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVERS_JSON="$SCRIPT_DIR/servers.json"

## Database: check local final_app/ folder first, then project references
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

MCP_PORT="${MCP_PORT:-8008}"

## ── Auto-detect Python path ──────────────────────────────────────────────────
CONDA_ENV="${CONDA_ENV:-mcp_env}"

## Try conda env first, then fall back to system python3
if command -v conda &>/dev/null; then
  MCP_PYTHON="$(conda run -n "$CONDA_ENV" which python3 2>/dev/null)"
fi
if [ -z "$MCP_PYTHON" ] || [ ! -f "$MCP_PYTHON" ]; then
  ## Fallback: search common conda paths
  for candidate in     "$HOME/miniconda3/envs/$CONDA_ENV/bin/python3"     "$HOME/anaconda3/envs/$CONDA_ENV/bin/python3"     "/opt/conda/envs/$CONDA_ENV/bin/python3"; do
    if [ -f "$candidate" ]; then
      MCP_PYTHON="$candidate"
      break
    fi
  done
fi
if [ -z "$MCP_PYTHON" ]; then
  echo "ERROR: Could not find Python in conda env '$CONDA_ENV'"
  echo "Set CONDA_ENV to your environment name, or set MCP_PYTHON directly"
  exit 1
fi
echo "Using Python: $MCP_PYTHON"

## ── Verify Ollama is reachable before starting anything else ─────────────────
echo "Checking Ollama at localhost:11434..."
if ! curl -sf "http://localhost:11434/api/tags" >/dev/null 2>&1; then
  echo "WARNING: Ollama does not appear to be running at localhost:11434"
  echo "  Start it with: ollama serve &"
  echo "  Then ensure llama3.1:70b is pulled: ollama pull llama3.1:70b"
fi

## ── Generate servers.json dynamically ────────────────────────────────────────
## This makes the config portable — no hardcoded user paths
cat > "$SCRIPT_DIR/servers.json" << SERVERS_EOF
{
  "mcpServers": {
    "db_exploration": {
      "command": "$MCP_PYTHON",
      "args": ["$SCRIPT_DIR/mcp_servers/DB_exploration.py"]
    },
    "variant_analysis": {
      "command": "$MCP_PYTHON",
      "args": ["$SCRIPT_DIR/mcp_servers/variant_analysis.py"]
    },
    "genotype_analysis": {
      "command": "$MCP_PYTHON",
      "args": ["$SCRIPT_DIR/mcp_servers/genotype_analysis.py"]
    },
    "phenotype_data": {
      "command": "$MCP_PYTHON",
      "args": ["$SCRIPT_DIR/mcp_servers/phenotype_data.py"]
    },
    "clinvar_annotation": {
      "command": "$MCP_PYTHON",
      "args": ["$SCRIPT_DIR/mcp_servers/clinvar_annotation.py"]
    },
    "rvat_analysis": {
      "command": "$MCP_PYTHON",
      "args": ["$SCRIPT_DIR/mcp_servers/rvat_bridge.py"]
    }
  }
}
SERVERS_EOF
echo "servers.json generated for user: $(whoami)"

echo "================================================"
echo " Project ALS — final_app"
echo "================================================"
echo " User        : $USER"
echo " Conda env   : $CONDA_ENV"
echo " servers.json: $SERVERS_JSON"
echo " Database    : $RVAT_GDB_PATH"
echo " MCP port    : $MCP_PORT"
echo " Model       : llama3.1:70b (set in pipeline.R)"
echo "================================================"

if [ ! -f "$SERVERS_JSON" ]; then
  echo "ERROR: servers.json not found at $SERVERS_JSON"; exit 1
fi

## ── Start rvat plumber server ────────────────────────────────────────────────
RVAT_PORT="${RVAT_PORT:-8009}"
RVAT_LOG="$SCRIPT_DIR/rvat_server.log"

## Stop existing rvat server if running
pkill -u "$USER" -f "rvat_server.R" 2>/dev/null && sleep 1 || true

## Check if rvat_server.R exists
if [ -f "$SCRIPT_DIR/mcp_servers/rvat_server.R" ]; then
  echo "Starting rvat plumber server on port $RVAT_PORT..."
  RVAT_GDB_PATH="$RVAT_GDB_PATH" RVAT_PORT="$RVAT_PORT" \
    Rscript -e "plumber::plumb('$SCRIPT_DIR/mcp_servers/rvat_server.R')\$run(port=$RVAT_PORT, host='0.0.0.0')" \
    > "$RVAT_LOG" 2>&1 &
  RVAT_PID=$!
  echo "rvat server started (pid $RVAT_PID), log: $RVAT_LOG"
  ## Wait for rvat server to be ready
  for i in $(seq 1 30); do
    if curl -sf "http://localhost:$RVAT_PORT/status" >/dev/null 2>&1; then
      echo "rvat server ready ✓  (after ${i}s)"
      break
    fi
    sleep 1
  done
else
  echo "rvat_server.R not found — skipping rvat server"
fi

## ── Stop existing mcpo process ───────────────────────────────────────────────
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
  2>/dev/null || echo "  (could not list tools — this is cosmetic, tools still work; verify with a direct curl test)"

echo ""
echo "================================================"
echo " Ready!"
echo "  MCP server → http://localhost:$MCP_PORT"
echo "  Docs       → http://localhost:$MCP_PORT/docs"
echo "  Then launch the app: R -e \"shiny::runApp('final_app.R')\""
echo "================================================"