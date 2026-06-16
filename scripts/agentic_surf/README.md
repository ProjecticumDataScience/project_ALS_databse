# agentic_surf — ALS MCP Pipeline (SURF HPC Server)

This is the **SURF HPC Cloud** version of the agentic pipeline.
The posit (default) version lives in `agentic/`.

## What's different from agentic/

| File | Change |
|------|--------|
| `app2.R` | SURF-specific fixes — patch this manually |
| `config.R` | (in benchmark_surf) — points to `llama3.1:70b` and SURF paths |
| `servers.json` | SURF server addresses — patch this manually |
| `rvat_server.log` | Not tracked — generated fresh on each run |

All MCP servers (`mcp_servers/`) are identical to the posit version
unless you have made SURF-specific changes.

## Setup

```bash
# Start all MCP services
bash start_services.sh

# Verify Ollama is running with 70b model
curl http://localhost:11434/api/tags
```

## Paths (on SURF server, user rjansen4)

- Repo root:   `~/project_ALS_databse/`
- This dir:    `~/project_ALS_databse/scripts/agentic_surf/`
- Benchmark:   `~/project_ALS_databse/scripts/benchmark_surf/`
- GDB file:    `~/project_ALS_databse/data/rvatData.gdb`
- Ollama:      `http://localhost:11434`
- MCP base:    `http://localhost:8008`
