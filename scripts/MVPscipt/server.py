#!/usr/bin/env python3
# ══════════════════════════════════════════════════════════════════════════════
# rvatData MCP Server — SQLite implementation for ALS variant analysis
# ══════════════════════════════════════════════════════════════════════════════
import os
import sqlite3
from typing import Any
from mcp.server.fastmcp import FastMCP

## Database path: set by start_services.sh via RVAT_GDB_PATH,
## or falls back to rvatData.gdb in the same folder as this script.
import pathlib
_script_dir = pathlib.Path(__file__).parent.resolve()
_local_db   = str(_script_dir / "rvatData.gdb")

DB_PATH = os.path.expanduser(
    os.environ.get("RVAT_GDB_PATH", _local_db)
)

mcp = FastMCP("rvatData MCP Server")


# ── Helper functions ──────────────────────────────────────────────────────────

def get_con():
    """Open a read-only SQLite connection via URI."""
    uri = f"file:{DB_PATH}?mode=ro"
    return sqlite3.connect(uri, uri=True)


def _query(sql: str, params: tuple = (), max_rows: int = 200) -> list[dict]:
    """Execute a safe read-only SELECT query and return at most max_rows rows."""
    if not sql.strip().upper().startswith("SELECT"):
        raise ValueError("Only SELECT queries are allowed.")
    con = get_con()
    try:
        con.row_factory = sqlite3.Row
        cur = con.execute(sql, params)
        rows = cur.fetchmany(max_rows)
        return [dict(r) for r in rows]
    finally:
        con.close()


def _scalar(sql: str, params: tuple = ()) -> Any:
    """Return a single scalar value."""
    rows = _query(sql, params, max_rows=1)
    if rows:
        return list(rows[0].values())[0]
    return None


# ══════════════════════════════════════════════════════════════════════════════
# 1. SCHEMA / EXPLORATION
# ══════════════════════════════════════════════════════════════════════════════

@mcp.tool()
def list_tables() -> list[str]:
    """List all tables in the database."""
    con = get_con()
    try:
        cur = con.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        return [r[0] for r in cur.fetchall()]
    finally:
        con.close()


@mcp.tool()
def describe_table(table_name: str) -> list[dict]:
    """
    Describe the columns of a table (name, type, notnull).

    Args:
        table_name: Name of the table
    """
    con = get_con()
    try:
        con.row_factory = sqlite3.Row
        cur = con.execute(f"PRAGMA table_info({table_name})")
        rows = cur.fetchall()
        return [{"name": r["name"], "type": r["type"], "notnull": r["notnull"]} for r in rows]
    finally:
        con.close()


@mcp.tool()
def get_sample_rows(table_name: str, n: int = 5) -> list[dict]:
    """
    Return the first n rows of a table.

    Args:
        table_name: Name of the table
        n: Number of rows (default 5)
    """
    return _query(f"SELECT * FROM {table_name} LIMIT {int(n)}")


# ══════════════════════════════════════════════════════════════════════════════
# 2. GENERIC QUERY TOOL
# ══════════════════════════════════════════════════════════════════════════════

@mcp.tool()
def run_query(sql: str) -> list[dict]:
    """
    Execute any read-only SELECT query (max 200 rows).

    AVAILABLE COLUMNS IN varInfo_synthetic:
      VAR_id, CHROM, POS, ID, REF, ALT, QUAL, FILTER,
      AC, AN, AF (global allele frequency — NO population-specific AF),
      gene_name,
      HighImpact (0/1), ModerateImpact (0/1), Synonymous (0/1),
      CADDphred (higher = more deleterious),
      SIFT  : 'D' = deleterious, 'T' = tolerated,
      PolyPhen: 'D' = probably damaging, 'P' = possibly damaging, 'B' = benign,
      ALS_1 .. ALS_5, Control_1 .. Control_5
        (genotype: 0 = hom-ref, 1 = heterozygous, 2 = hom-alt)
      Missing values for CADDphred, PolyPhen, SIFT are stored as '.' not NULL.

    NOT AVAILABLE:
      - Age of patients or controls
      - Pathogenicity status (e.g. ClinVar)
      - Population-specific allele frequencies (EUR, SAS, AFR)
      - Sex of carriers
      - Previous publications or reports about variants

    IMPOSSIBLE COMBINATIONS:
      - A variant CANNOT be both Synonymous=1 AND HighImpact=1.

    Args:
        sql: SELECT statement
    """
    return _query(sql)


# ══════════════════════════════════════════════════════════════════════════════
# 3. LOOKUP QUERIES
# ══════════════════════════════════════════════════════════════════════════════

@mcp.tool()
def count_variants_in_gene(gene: str) -> list[dict]:
    """
    Count the number of variants in a gene.

    Args:
        gene: Gene name, e.g. 'NEK1'
    """
    return _query(
        "SELECT COUNT(VAR_id) AS number_of_variants "
        "FROM varInfo_synthetic "
        "WHERE gene_name = ?",
        (gene,)
    )


@mcp.tool()
def get_high_impact_variants_in_gene(gene: str, cadd_min: float = 20.0) -> list[dict]:
    """
    Select variants in a gene with HighImpact and CADDphred above a threshold.

    Args:
        gene: Gene name
        cadd_min: Minimum CADDphred score (default 20)
    """
    return _query(
        "SELECT VAR_id, gene_name, HighImpact, CADDphred "
        "FROM varInfo_synthetic "
        "WHERE HighImpact = 1 AND CADDphred > ? AND gene_name = ?",
        (cadd_min, gene)
    )


@mcp.tool()
def count_sift_deleterious_in_gene(gene: str) -> list[dict]:
    """
    Count variants in a gene predicted deleterious by SIFT.

    Args:
        gene: Gene name
    """
    return _query(
        "SELECT COUNT(*) AS number_of_variants_with_SIFT_D "
        "FROM varInfo_synthetic "
        "WHERE gene_name = ? AND SIFT = 'D'",
        (gene,)
    )


@mcp.tool()
def get_high_impact_homozygous_ALS() -> list[dict]:
    """
    Return high-impact variants where at least one ALS patient is homozygous
    (genotype = 2).
    """
    return _query(
        "SELECT VAR_id, gene_name, HighImpact, "
        "       ALS_1, ALS_2, ALS_3, ALS_4, ALS_5 "
        "FROM varInfo_synthetic "
        "WHERE HighImpact = 1 "
        "  AND (ALS_1 = 2 OR ALS_2 = 2 OR ALS_3 = 2 OR ALS_4 = 2 OR ALS_5 = 2)"
    )


@mcp.tool()
def get_top_deleterious_in_gene(gene: str, top_n: int = 10) -> list[dict]:
    """
    Return the most deleterious variants in a gene (CADD + SIFT + PolyPhen).
    Definition: CADDphred > 20 AND SIFT = 'D' AND PolyPhen = 'D'.

    Args:
        gene: Gene name
        top_n: Number of variants to return (default 10)
    """
    return _query(
        "SELECT VAR_id, gene_name, CADDphred, SIFT, PolyPhen "
        "FROM varInfo_synthetic "
        "WHERE CADDphred > 20 AND SIFT = 'D' AND PolyPhen = 'D' AND gene_name = ? "
        "ORDER BY CADDphred DESC "
        f"LIMIT {int(top_n)}",
        (gene,)
    )


# ══════════════════════════════════════════════════════════════════════════════
# 4. ANALYTICAL QUERIES
# ══════════════════════════════════════════════════════════════════════════════

@mcp.tool()
def get_highest_af_variant() -> list[dict]:
    """Return the variant with the highest allele frequency."""
    return _query(
        "SELECT VAR_id, MAX(AF) AS highest_allele_frequency "
        "FROM varInfo_synthetic"
    )


@mcp.tool()
def get_average_af_by_impact() -> list[dict]:
    """Average allele frequency per impact category (Synonymous, ModerateImpact, HighImpact)."""
    return _query(
        "SELECT "
        "  AVG(CASE WHEN Synonymous     = 1 THEN AF END) AS average_AF_synonymous, "
        "  AVG(CASE WHEN ModerateImpact = 1 THEN AF END) AS average_AF_moderate, "
        "  AVG(CASE WHEN HighImpact     = 1 THEN AF END) AS average_AF_high "
        "FROM varInfo_synthetic"
    )


@mcp.tool()
def get_high_impact_burden_per_sample(sample_id: str) -> list[dict]:
    """
    How many high-impact variants does a given sample carry?
    Returns the number of heterozygous (genotype=1) and homozygous (genotype=2) variants.

    Args:
        sample_id: Sample name, e.g. 'ALS_1' or 'Control_3'
    """
    allowed = [f"ALS_{i}" for i in range(1, 6)] + [f"Control_{i}" for i in range(1, 6)]
    if sample_id not in allowed:
        raise ValueError(f"Unknown sample '{sample_id}'. Choose from: {', '.join(allowed)}")
    return _query(
        f"SELECT "
        f"  SUM(CASE WHEN {sample_id} = 1 THEN 1 ELSE 0 END) AS heterozygous, "
        f"  SUM(CASE WHEN {sample_id} = 2 THEN 1 ELSE 0 END) AS homozygous "
        f"FROM varInfo_synthetic "
        f"WHERE HighImpact = 1"
    )


@mcp.tool()
def get_total_burden_cases_vs_controls() -> list[dict]:
    """
    Total allele burden (effect alleles) for cases vs. controls.
    Each carrier contributes their genotype value (0/1/2) to the total sum.
    """
    return _query(
        "SELECT "
        "  SUM(ALS_1 + ALS_2 + ALS_3 + ALS_4 + ALS_5) AS total_cases_burden, "
        "  SUM(Control_1 + Control_2 + Control_3 + Control_4 + Control_5) AS total_controls_burden "
        "FROM varInfo_synthetic"
    )


@mcp.tool()
def get_top_case_enriched_variants(top_n: int = 10) -> list[dict]:
    """
    Top variants with the highest case/control ratio (allele count).

    Args:
        top_n: Number of variants to return (default 10)
    """
    return _query(
        "SELECT "
        "  VAR_id, gene_name, "
        "  (ALS_1 + ALS_2 + ALS_3 + ALS_4 + ALS_5) AS case_count, "
        "  (Control_1 + Control_2 + Control_3 + Control_4 + Control_5) AS control_count, "
        "  ((ALS_1 + ALS_2 + ALS_3 + ALS_4 + ALS_5) * 1.0) / "
        "    NULLIF((Control_1 + Control_2 + Control_3 + Control_4 + Control_5), 0) "
        "    AS case_control_ratio "
        "FROM varInfo_synthetic "
        "ORDER BY case_control_ratio DESC "
        f"LIMIT {int(top_n)}"
    )


@mcp.tool()
def summarize_variants_by_gene(min_variants: int = 10, order_by: str = "total_variants") -> list[dict]:
    """
    Summary per gene: variant counts, impact breakdown, mean AF and genomic position.
    Only genes with more than min_variants variants are included.

    Args:
        min_variants: Minimum number of variants (default 10)
        order_by: Column to sort by: total_variants, high_impact_count,
                  moderate_impact_count, mean_AF, or length (default total_variants)
    """
    allowed_order = {"total_variants", "high_impact_count", "moderate_impact_count", "mean_AF", "length"}
    if order_by not in allowed_order:
        order_by = "total_variants"
    return _query(
        "SELECT "
        "  gene_name, CHROM, "
        "  COUNT(*) AS total_variants, "
        "  SUM(CASE WHEN HighImpact     = 1 THEN 1 ELSE 0 END) AS high_impact_count, "
        "  SUM(CASE WHEN ModerateImpact = 1 THEN 1 ELSE 0 END) AS moderate_impact_count, "
        "  SUM(CASE WHEN Synonymous     = 1 THEN 1 ELSE 0 END) AS synonymous_count, "
        "  ROUND(AVG(AF), 8) AS mean_AF, "
        "  MIN(POS) AS start_pos, "
        "  MAX(POS) AS end_pos, "
        "  (MAX(POS) - MIN(POS)) AS length "
        "FROM varInfo_synthetic "
        "GROUP BY gene_name, CHROM "
        f"HAVING total_variants > {int(min_variants)} "
        f"ORDER BY {order_by} DESC"
    )


# ══════════════════════════════════════════════════════════════════════════════
# 5. CARRIER ANALYSIS
# ══════════════════════════════════════════════════════════════════════════════

@mcp.tool()
def get_carriers_by_gene(gene: str, group: str = "ALS") -> list[dict]:
    """
    Return variants in a gene where at least one person in the group is a carrier.

    Args:
        gene: Gene name
        group: 'ALS' or 'Control'
    """
    group_upper = group.strip().upper()
    if group_upper == "ALS":
        cols = [f"ALS_{i}" for i in range(1, 6)]
    elif group_upper == "CONTROL":
        cols = [f"Control_{i}" for i in range(1, 6)]
    else:
        raise ValueError("group must be 'ALS' or 'Control'.")
    carrier_filter = " OR ".join(f"{c} > 0" for c in cols)
    return _query(
        f"SELECT VAR_id, CHROM, POS, REF, ALT, gene_name, "
        f"       CADDphred, SIFT, PolyPhen, HighImpact, "
        f"       ALS_1, ALS_2, ALS_3, ALS_4, ALS_5, "
        f"       Control_1, Control_2, Control_3, Control_4, Control_5 "
        f"FROM varInfo_synthetic "
        f"WHERE gene_name = ? AND ({carrier_filter})",
        (gene,)
    )


@mcp.tool()
def get_variants_by_gene_and_impact(gene: str, impact: str, limit: int = 200) -> list[dict]:
    """
    Return variants for a gene filtered by impact level.

    Args:
        gene: Gene name
        impact: 'HIGH', 'MODERATE', or 'SYNONYMOUS'
        limit: Maximum number of rows (default 200)
    """
    impact_map = {"HIGH": "HighImpact", "MODERATE": "ModerateImpact", "SYNONYMOUS": "Synonymous"}
    col = impact_map.get(impact.strip().upper())
    if not col:
        raise ValueError("impact must be 'HIGH', 'MODERATE' or 'SYNONYMOUS'.")
    return _query(
        f"SELECT VAR_id, CHROM, POS, REF, ALT, gene_name, "
        f"       HighImpact, ModerateImpact, Synonymous, "
        f"       CADDphred, SIFT, PolyPhen, AF "
        f"FROM varInfo_synthetic "
        f"WHERE gene_name = ? AND {col} = 1 "
        f"ORDER BY CADDphred DESC "
        f"LIMIT {int(limit)}",
        (gene,)
    )


# ══════════════════════════════════════════════════════════════════════════════
# 6. DATABASE SUMMARY
# ══════════════════════════════════════════════════════════════════════════════

@mcp.tool()
def summarize_database() -> dict:
    """Global statistics of the varInfo_synthetic table."""
    con = get_con()
    try:
        def s(sql):
            return con.execute(sql).fetchone()[0]
        return {
            "total_variants":       s("SELECT COUNT(*)                  FROM varInfo_synthetic"),
            "unique_genes":         s("SELECT COUNT(DISTINCT gene_name) FROM varInfo_synthetic"),
            "high_impact":          s("SELECT COUNT(*) FROM varInfo_synthetic WHERE HighImpact = 1"),
            "moderate_impact":      s("SELECT COUNT(*) FROM varInfo_synthetic WHERE ModerateImpact = 1"),
            "synonymous":           s("SELECT COUNT(*) FROM varInfo_synthetic WHERE Synonymous = 1"),
            "sift_deleterious":     s("SELECT COUNT(*) FROM varInfo_synthetic WHERE SIFT = 'D'"),
            "polyphen_damaging":    s("SELECT COUNT(*) FROM varInfo_synthetic WHERE PolyPhen = 'D'"),
            "mean_allele_freq":     s("SELECT ROUND(AVG(AF), 6) FROM varInfo_synthetic"),
            "database_path":        DB_PATH,
            "genome_build":         "GRCh38",
            "not_available":        (
                "Age, sex of carriers, population-specific AF, "
                "pathogenicity status (ClinVar), previous publications."
            ),
        }
    finally:
        con.close()


# ══════════════════════════════════════════════════════════════════════════════
# 7. DATABASE LIMITATIONS
# ══════════════════════════════════════════════════════════════════════════════

@mcp.tool()
def get_database_limitations() -> dict:
    """
    Explicitly describes what is NOT available in the database.
    Call this before answering a question that may be outside the available data.
    """
    return {
        "missing_fields": {
            "age": {
                "available": False,
                "explanation": (
                    "No age information is available for cases or controls. "
                    "Questions like 'what is the average age of ALS patients' "
                    "CANNOT be answered."
                ),
            },
            "sex_of_carriers": {
                "available": False,
                "explanation": (
                    "varInfo_synthetic has no sex column. The SM table has a "
                    "sex column (IID, sex), but it is not linked to the genotype "
                    "columns ALS_1..ALS_5 / Control_1..Control_5. "
                    "Questions like 'how many female carriers are there' CANNOT "
                    "be answered via SQLite alone."
                ),
            },
            "population_specific_AF": {
                "available": False,
                "explanation": (
                    "The AF column is a global allele frequency. There are no "
                    "population-specific frequencies (EUR, SAS, AFR etc.). "
                    "Questions like 'what is the AF in Europeans' CANNOT be answered."
                ),
            },
            "pathogenicity": {
                "available": False,
                "explanation": (
                    "No pathogenicity information (e.g. ClinVar classification) is available. "
                    "Questions like 'is variant X pathogenic' CANNOT be answered."
                ),
            },
            "previous_reports": {
                "available": False,
                "explanation": (
                    "No information about previously published variants is available. "
                    "Questions like 'has VAR_id 100 been reported before' CANNOT be answered."
                ),
            },
        },
        "impossible_combinations": {
            "synonymous_and_high_impact": {
                "possible": False,
                "explanation": (
                    "A variant CANNOT be both synonymous (no amino acid change) "
                    "AND high-impact at the same time."
                ),
            },
        },
        "vague_or_subjective": {
            "most_important_variants": {
                "action": "Ask for clarification",
                "explanation": (
                    "'Most important' is subjective. Clarify: does the user mean "
                    "highest CADD score, high-impact, strongest case-enrichment, or something else?"
                ),
            },
            "most_deleterious": {
                "action": "Define and state the definition",
                "explanation": (
                    "'Most deleterious' is ambiguous. Preferably use a combination "
                    "of CADDphred, SIFT=D and PolyPhen=D, and always state which definition was used."
                ),
            },
        },
        "advanced_rvat": {
            "available_via_sql": False,
            "explanation": (
                "Population-stratified analyses, MAF calculations per cohort and "
                "burden tests require the R package rvat and cannot be done via SQLite alone."
            ),
        },
    }


# ══════════════════════════════════════════════════════════════════════════════
# ENTRYPOINT
# ══════════════════════════════════════════════════════════════════════════════

if __name__ == "__main__":
    mcp.run(transport="stdio")
