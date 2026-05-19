import os
import sqlite3
import json
from pathlib import Path
from mcp.server.fastmcp import FastMCP

SCRIPT_DIR  = Path(__file__).parent
PROJECT_DIR = SCRIPT_DIR.parent.parent
GDB_PATH    = os.getenv("RVAT_GDB_PATH", str(PROJECT_DIR / "rvatData.gdb"))
TABLE       = os.getenv("RVAT_TABLE",    "varInfo_synthetic")

def get_conn():
    if not Path(GDB_PATH).exists():
        raise FileNotFoundError(f"Database niet gevonden: {GDB_PATH}")
    conn = sqlite3.connect(f"file:{GDB_PATH}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    return conn

def run_query(sql, params=()):
    with get_conn() as conn:
        cur = conn.execute(sql, params)
        return [dict(r) for r in cur.fetchall()]

def j(obj):
    return json.dumps(obj, indent=2, default=str)

mcp = FastMCP(name="rvat-als")

@mcp.tool()
def query_variants(sql: str) -> str:
    """Voer een SELECT query uit op de variant database (tabel: varInfo_synthetic)."""
    sql = sql.strip()
    if not sql.upper().startswith("SELECT"):
        return "Fout: alleen SELECT queries zijn toegestaan."
    if "LIMIT" not in sql.upper():
        sql += " LIMIT 200"
    try:
        return j(run_query(sql)[:500])
    except Exception as e:
        return f"Query fout: {e}"

@mcp.tool()
def get_schema() -> str:
    """Geef de kolomnamen en typen van de variant tabel."""
    try:
        rows = run_query(f"PRAGMA table_info({TABLE})")
        return j([{"name": r["name"], "type": r["type"]} for r in rows])
    except Exception as e:
        return f"Fout: {e}"

@mcp.tool()
def get_variants_by_gene(gene: str, limit: int = 100) -> str:
    """Haal alle varianten op voor een gen, bijv. NEK1."""
    try:
        rows = run_query(
            f"SELECT * FROM {TABLE} WHERE UPPER(gene) = UPPER(?) LIMIT ?",
            (gene, min(int(limit), 500))
        )
        return j(rows) if rows else f"Geen varianten gevonden voor '{gene}'."
    except Exception as e:
        return f"Fout: {e}"

@mcp.tool()
def count_variants_by_gene(top_n: int = 20) -> str:
    """Tel varianten per gen, gesorteerd van hoog naar laag."""
    try:
        return j(run_query(
            f"SELECT gene, COUNT(*) AS n FROM {TABLE} GROUP BY gene ORDER BY n DESC LIMIT ?",
            (int(top_n),)
        ))
    except Exception as e:
        return f"Fout: {e}"

@mcp.tool()
def get_variants_by_impact(impact: str, limit: int = 100) -> str:
    """Filter varianten op impact: HIGH, MODERATE, LOW of MODIFIER."""
    if impact.upper() not in {"HIGH","MODERATE","LOW","MODIFIER"}:
        return "Ongeldig impact. Kies uit: HIGH, MODERATE, LOW, MODIFIER."
    try:
        rows = run_query(
            f"SELECT * FROM {TABLE} WHERE UPPER(impact) = UPPER(?) LIMIT ?",
            (impact, min(int(limit), 500))
        )
        return j(rows) if rows else f"Geen varianten met impact '{impact}'."
    except Exception as e:
        return f"Fout: {e}"

@mcp.tool()
def get_deleterious_variants(predictor: str = "SIFT", limit: int = 100) -> str:
    """Varianten voorspeld als schadelijk door SIFT, PolyPhen of CADD."""
    limit = min(int(limit), 500)
    try:
        p = predictor.upper()
        if p == "SIFT":
            rows = run_query(f"SELECT * FROM {TABLE} WHERE UPPER(sift_pred)='D' LIMIT ?", (limit,))
        elif p == "POLYPHEN":
            rows = run_query(f"SELECT * FROM {TABLE} WHERE UPPER(polyphen_pred) IN ('D','P') LIMIT ?", (limit,))
        elif p == "CADD":
            rows = run_query(f"SELECT * FROM {TABLE} WHERE cadd_phred >= 20 LIMIT ?", (limit,))
        else:
            return "Onbekende predictor. Gebruik SIFT, PolyPhen of CADD."
        return j(rows) if rows else f"Geen schadelijke varianten voor '{predictor}'."
    except Exception as e:
        return f"Fout: {e}"

@mcp.tool()
def summarize_database() -> str:
    """Geef statistieken: totaal varianten, genen, impact-verdeling."""
    try:
        return j({
            "totaal_varianten": run_query(f"SELECT COUNT(*) AS n FROM {TABLE}")[0]["n"],
            "totaal_genen":     run_query(f"SELECT COUNT(DISTINCT gene) AS n FROM {TABLE}")[0]["n"],
            "per_impact":       run_query(f"SELECT impact, COUNT(*) AS n FROM {TABLE} GROUP BY impact ORDER BY n DESC"),
            "database":         GDB_PATH,
            "tabel":            TABLE,
        })
    except Exception as e:
        return f"Fout: {e}"

@mcp.tool()
def list_tables() -> str:
    """Lijst alle tabellen in de database."""
    try:
        return j([r["name"] for r in run_query("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")])
    except Exception as e:
        return f"Fout: {e}"

if __name__ == "__main__":
    print(f"MCP server gestart\n  Database: {GDB_PATH}\n  Tabel:    {TABLE}")
    mcp.run()
