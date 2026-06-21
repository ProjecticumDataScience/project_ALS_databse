#!/usr/bin/env python3
# ══════════════════════════════════════════════════════════════════════════════
# DB_exploration.py — Schema and database metadata tools
# Use these tools first to understand what data is available before querying.
# ══════════════════════════════════════════════════════════════════════════════
import os
import sqlite3
import pathlib
from mcp.server.fastmcp import FastMCP

_script_dir = pathlib.Path(__file__).parent.resolve()
DB_PATH = os.path.expanduser(
    os.environ.get("RVAT_GDB_PATH", str(_script_dir.parent / "rvatData.gdb"))
)

mcp = FastMCP("DB_exploration")


def get_con():
    uri = f"file:{DB_PATH}?mode=ro"
    con = sqlite3.connect(uri, uri=True)
    con.row_factory = sqlite3.Row
    return con


def _query(sql: str, params: tuple = (), max_rows: int = 200) -> list[dict]:
    if not sql.strip().upper().startswith("SELECT"):
        raise ValueError("Only SELECT queries are allowed.")
    con = get_con()
    try:
        cur = con.execute(sql, params)
        return [dict(r) for r in cur.fetchmany(max_rows)]
    finally:
        con.close()


@mcp.tool()
def list_tables() -> list[str]:
    """
    List all queryable tables in the rvatData database.
    Call this first to understand what data is available.

    Queryable tables:
      - varInfo_synthetic : variants with synthetic genotypes (ALS_1..5, Control_1..5)
      - varInfo           : variants without genotype columns (real population data)
      - pheno             : sample phenotypes (IID, sex, pheno, pop, superPop, age)
      - SM                : sample metadata (IID, sex) — simpler version of pheno
      - meta              : database metadata (rvatVersion, genomeBuild)
    """
    con = get_con()
    try:
        rows = con.execute(
            "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
        ).fetchall()
        queryable = {"varInfo_synthetic", "varInfo", "pheno", "SM", "meta", "var"}
        return [r[0] for r in rows if r[0] in queryable]
    finally:
        con.close()


@mcp.tool()
def describe_table(table_name: str) -> list[dict]:
    """
    Describe the columns of a table: name, type, and whether null is allowed.
    Use before writing queries to understand the schema.

    Args:
        table_name: One of: varInfo_synthetic, varInfo, pheno, SM, meta, var
    """
    con = get_con()
    try:
        con.row_factory = sqlite3.Row
        cur = con.execute(f"PRAGMA table_info({table_name})")
        return [{"name": r["name"], "type": r["type"], "notnull": r["notnull"]}
                for r in cur.fetchall()]
    finally:
        con.close()


@mcp.tool()
def get_sample_rows(table_name: str, n: int = 5) -> list[dict]:
    """
    Return a small sample of rows from a table.
    Useful to understand data format before writing queries.

    Args:
        table_name: Table to sample
        n: Number of rows to return (default 5, max 20)
    """
    n = min(int(n), 20)
    return _query(f"SELECT * FROM {table_name} LIMIT {n}")


@mcp.tool()
def get_database_info() -> dict:
    """
    Return overall database metadata and statistics.
    Use for overview questions about the database.
    """
    con = get_con()
    try:
        def s(sql): return con.execute(sql).fetchone()[0]
        meta_rows = {r[0]: r[1] for r in con.execute("SELECT name, value FROM meta").fetchall()}
        return {
            "genome_build":          meta_rows.get("genomeBuild", "GRCh38"),
            "rvat_version":          meta_rows.get("rvatVersion", "unknown"),
            "total_variants":        s("SELECT COUNT(*) FROM varInfo_synthetic"),
            "unique_genes":          s("SELECT COUNT(DISTINCT gene_name) FROM varInfo_synthetic"),
            "high_impact":           s("SELECT COUNT(*) FROM varInfo_synthetic WHERE HighImpact='1'"),
            "moderate_impact":       s("SELECT COUNT(*) FROM varInfo_synthetic WHERE ModerateImpact='1'"),
            "synonymous":            s("SELECT COUNT(*) FROM varInfo_synthetic WHERE Synonymous='1'"),
            "total_samples":         s("SELECT COUNT(*) FROM pheno"),
            "als_cases":             s("SELECT COUNT(*) FROM pheno WHERE pheno=1"),
            "controls":              s("SELECT COUNT(*) FROM pheno WHERE pheno=0"),
            "not_available": [
                "Age per sample is in pheno table but not linked to genotype columns by name",
                "Population-specific allele frequencies (only global AF available)",
                "ClinVar pathogenicity classification",
                "Previous publication status of variants",
            ],
        }
    finally:
        con.close()


@mcp.tool()
def get_database_limitations() -> dict:
    """
    Describes what is NOT available in this database.
    Call this before answering questions that may require unavailable data.
    """
    return {
        "missing_data": {
            "pathogenicity": "No ClinVar or pathogenicity classification. SIFT/PolyPhen/CADD are computational predictions only.",
            "population_af": "AF column is global only. No population-specific frequencies (EUR, SAS, AFR etc.).",
            "previous_reports": "No information about previously published variants.",
        },
        "linkage_challenge": {
            "genotype_to_pheno": (
                "varInfo_synthetic genotype columns (ALS_1..ALS_5, Control_1..Control_5) "
                "map to IID values in pheno by removing the underscore: ALS_1 → IID 'ALS1'. "
                "This join is possible but requires CASE WHEN logic."
            ),
        },
        "impossible_combinations": {
            "synonymous_and_high_impact": "A variant cannot be both Synonymous=1 AND HighImpact=1.",
        },
        "rvat_only": {
            "burden_tests": "Statistical burden tests (SKAT, CMC etc.) require the rvat R package.",
            "maf_per_cohort": "MAF calculations per cohort require rvat buildVarSet.",
        },
    }


if __name__ == "__main__":
    mcp.run(transport="stdio")