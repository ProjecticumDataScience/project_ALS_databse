# Project MinE ALS — Agentic Variant Assistant

LLM-powered chatbot for querying the Project MinE ALS variant database (`rvatData.gdb`).  
Built on a multi-server MCP architecture with support for SQL queries, phenotype joins,  
ClinVar annotation, and real statistical burden testing via rvat.

---

## Architecture

```
User question
     │
     ▼
classify_complexity()          ← keyword pre-check + LLM fallback
     │
     ├─ "simple"  → run_single_pipeline()  / run_dual_pipeline()
     └─ "complex" → run_agentic_pipeline() (max 5 steps)
                         │
                         ▼
                    [MCP Tools] ─────────────────────────────────────────────
                    │ db_exploration   │ schema, limitations, DB info        │
                    │ variant_analysis │ SQL on varInfo_synthetic            │
                    │ genotype_analysis│ carrier/burden queries              │
                    │ phenotype_data   │ multi-table joins with pheno table  │
                    │ clinvar_annotation│ ClinVar lookup via rsID            │
                    │ rvat_analysis    │ statistical burden/single-var tests │
                    └────────────────────────────────────────────────────────
                         │
                         ▼
                    summarize_result() → response to user
```

### Pipeline modes (selectable in UI)

| Mode | Description | Best for |
|------|-------------|----------|
| Single — llama3.1:8b | One LLM, classify + execute | Speed |
| Two LLM — llama3.1 + duckdb-nsql | duckdb-nsql refines SQL | Complex SQL |
| Two LLM — llama3.1 + llama3.1 | Same model twice | Reasoning |
| Adaptive ★ | duckdb-nsql for SQL, llama3.1 for tools | Best overall |

---

## Requirements

### Software
- **R** ≥ 4.4 with packages: `shiny`, `bslib`, `DT`, `httr2`, `jsonlite`, `shinyjs`, `plumber`, `rvat`
- **Python** ≥ 3.10 in conda env `mcp_env` with: `mcp`, `mcpo`, `fastmcp`
- **Ollama** running on `localhost:11434` with models: `llama3.1:8b`, `duckdb-nsql`
- **mcpo** for multi-server MCP proxying

### Conda environment
```bash
conda activate mcp_env
```

### Install plumber (first time only)
```r
install.packages("plumber")
```

---

## Setup

### 1. Configuration

Edit `start_services.sh` to set your paths:

```bash
# Required: path to rvatData.gdb
export RVAT_GDB_PATH="$HOME/project_ALS_databse/references/rvatData.gdb"

# Optional: conda environment name (default: mcp_env)
export CONDA_ENV="mcp_env"
```

The script auto-detects your conda Python path and generates `servers.json` at startup —
**no manual editing of servers.json needed**.

### 2. Build ClinVar cache (first time only, ~20 min)

```bash
cd ~/project_ALS_databse/scripts/agentic
conda activate mcp_env
RVAT_GDB_PATH=~/project_ALS_databse/references/rvatData.gdb \
  python3 mcp_servers/clinvar_annotation.py --build-cache
```

This fetches ClinVar data for all 1157 rsIDs in the database and stores them locally.
Subsequent starts are instant (fully offline).

### 3. Start all services

```bash
cd ~/project_ALS_databse/scripts/agentic
bash start_services.sh
```

This starts:
1. **rvat plumber server** on port 8009
2. **mcpo multi-server proxy** on port 8008

Verify everything is running:
```bash
curl -s http://localhost:8008/db_exploration/openapi.json | python3 -c \
  "import json,sys; [print(p) for p in json.load(sys.stdin)['paths']]"
curl -s http://localhost:8009/status | python3 -m json.tool
```

### 4. Launch the Shiny app

Open `app2.R` in RStudio and click **Run App**, or:
```r
shiny::runApp("~/project_ALS_databse/scripts/agentic/app2.R")
```

---

## MCP Servers

### Python servers (via mcpo on port 8008)

| Server | Port path | Description |
|--------|-----------|-------------|
| `db_exploration` | `/db_exploration/` | Database schema, limitations, metadata |
| `variant_analysis` | `/variant_analysis/` | SQL queries on varInfo_synthetic |
| `genotype_analysis` | `/genotype_analysis/` | Carrier/burden analysis |
| `phenotype_data` | `/phenotype_data/` | Multi-table joins with pheno/SM tables |
| `clinvar_annotation` | `/clinvar_annotation/` | ClinVar pathogenicity lookup |
| `rvat_analysis` | `/rvat_analysis/` | Bridge to R/plumber rvat server |

### R/plumber server (port 8009)

| Endpoint | Description |
|----------|-------------|
| `POST /run_burden_test` | Statistical burden test for one gene |
| `POST /run_burden_all_genes` | Burden test across all 12 genes |
| `POST /run_single_variant_test` | Per-variant association p-values |
| `POST /get_maf_by_impact` | MAF from genotype matrix |
| `POST /get_ld_matrix` | Pairwise LD (r²) between variants |
| `POST /get_variant_summary` | Genotype count summaries |
| `POST /get_carrier_info` | Sample-level carrier info |
| `GET  /status` | Server health check |

**Future versions of rvat:** Only `rvat_server.R` needs updating if rvat function  
signatures change. All other components are insulated.

---

## Database

**File:** `rvatData.gdb` (SQLite-based rvat gdb)

**Key tables:**
- `varInfo_synthetic` — 1802 variants, 12 genes, 10 genotype columns (ALS_1..ALS_5, Control_1..Control_5)
- `pheno` — 25000 samples with phenotype (1=ALS, 0=control), sex (1=female, 2=male), population

**Important data conventions:**
- Missing values stored as `'.'` not NULL
- HighImpact/ModerateImpact/Synonymous stored as TEXT `'0'`/`'1'`
- Always use `CAST(CADDphred AS REAL)` for numeric comparisons
- CHROM has `chr` prefix: `chrX` not `X`

---

## Running for a different user

1. Clone/copy the `scripts/agentic/` directory
2. Set `RVAT_GDB_PATH` in your environment or in `start_services.sh`
3. Ensure `mcp_env` conda environment exists (or set `CONDA_ENV` to your env name)
4. Run `bash start_services.sh` — `servers.json` is generated automatically
5. Build ClinVar cache once (if not already built by another user, the cache is at `mcp_servers/clinvar_cache.db`)

---

## File structure

```
scripts/agentic/
├── app2.R                     ← Main Shiny app + pipeline logic
├── start_services.sh          ← Service launcher (edit this for config)
├── servers.json               ← Auto-generated by start_services.sh
├── prompts.txt                ← Data description + extra instructions
├── mcp_servers/
│   ├── DB_exploration.py      ← Database metadata tools
│   ├── variant_analysis.py    ← Variant SQL tools
│   ├── genotype_analysis.py   ← Genotype/carrier tools
│   ├── phenotype_data.py      ← Phenotype join tools
│   ├── clinvar_annotation.py  ← ClinVar lookup + cache builder
│   ├── clinvar_cache.db       ← Local ClinVar SQLite cache (build once)
│   ├── rvat_server.R          ← R/plumber rvat statistical server
│   └── rvat_bridge.py         ← FastMCP bridge to plumber
└── rvat_server.log            ← rvat plumber server log (see note below)
```

### Note on rvat_server.log

`start_services.sh` redirects all rvat plumber output to `rvat_server.log`.  
This includes rvat progress messages like `Retrieved genotypes for N variants`  
and `[N/N] (25000 samples, N variants) pheno | sex | allelic`.  
These are normal — rvat is verbose by design. Check this file if the rvat  
server seems unresponsive:

```bash
tail -f ~/project_ALS_databse/scripts/agentic/rvat_server.log
```

---

## Stopping services

```bash
# Stop mcpo
kill $(ps aux | grep "mcpo.*8008" | grep -v grep | awk '{print $2}')

# Stop rvat plumber
fuser -k 8009/tcp
```