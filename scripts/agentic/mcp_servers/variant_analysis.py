#!/usr/bin/env python3
# ══════════════════════════════════════════════════════════════════════════════
# variant_analysis.py — Variant query and annotation tools
# Covers: counts, impact filters, CADD/SIFT/PolyPhen, allele frequency,
#         gene-level summaries. Uses varInfo_synthetic and varInfo tables.
# ══════════════════════════════════════════════════════════════════════════════
import os
import sqlite3
import pathlib
from mcp.server.fastmcp import FastMCP

_script_dir = pathlib.Path(__file__).parent.resolve()
DB_PATH = os.path.expanduser(
    os.environ.get("RVAT_GDB_PATH", str(_script_dir.parent / "rvatData.gdb"))
)

mcp = FastMCP("variant_analysis")


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
def count_variants_in_gene(gene: str) -> list[dict]:
    """
    Count the total number of variants in a specific gene.

    Args:
        gene: Gene name, e.g. 'NEK1', 'SOD1', 'TARDBP', 'ABCA4', 'FUS'
    """
    return _query(
        "SELECT COUNT(*) AS n_variants, gene_name "
        "FROM varInfo_synthetic WHERE gene_name = ?",
        (gene,)
    )


@mcp.tool()
def get_variants_in_gene(gene: str, impact: str = "all", limit: int = 100) -> list[dict]:
    """
    Return variants in a gene, optionally filtered by impact level.

    Args:
        gene:   Gene name
        impact: 'HIGH', 'MODERATE', 'SYNONYMOUS', or 'all' (default)
        limit:  Max rows to return (default 100)
    """
    impact_map = {
        "HIGH":       "HighImpact = '1'",
        "MODERATE":   "ModerateImpact = '1'",
        "SYNONYMOUS": "Synonymous = '1'",
        "ALL":        "1=1",
    }
    where = impact_map.get(impact.upper(), "1=1")
    return _query(
        f"SELECT VAR_id, CHROM, POS, REF, ALT, gene_name, "
        f"       HighImpact, ModerateImpact, Synonymous, "
        f"       CADDphred, SIFT, PolyPhen, AF "
        f"FROM varInfo_synthetic "
        f"WHERE gene_name = ? AND {where} "
        f"ORDER BY CASE WHEN CADDphred != '.' THEN CAST(CADDphred AS REAL) ELSE 0 END DESC "
        f"LIMIT {int(limit)}",
        (gene,)
    )


@mcp.tool()
def count_variants_by_impact() -> list[dict]:
    """
    Count variants grouped by impact category across all genes.
    Returns totals for HighImpact, ModerateImpact, and Synonymous.
    """
    return _query(
        "SELECT "
        "  SUM(CASE WHEN HighImpact='1' THEN 1 ELSE 0 END) AS high_impact, "
        "  SUM(CASE WHEN ModerateImpact='1' THEN 1 ELSE 0 END) AS moderate_impact, "
        "  SUM(CASE WHEN Synonymous='1' THEN 1 ELSE 0 END) AS synonymous, "
        "  COUNT(*) AS total "
        "FROM varInfo_synthetic"
    )


@mcp.tool()
def get_high_impact_variants_in_gene(gene: str, cadd_min: float = 20.0) -> list[dict]:
    """
    Return high-impact variants in a gene with CADDphred above a threshold.

    Args:
        gene:     Gene name
        cadd_min: Minimum CADDphred score (default 20.0)
    """
    return _query(
        "SELECT VAR_id, gene_name, HighImpact, CADDphred, SIFT, PolyPhen, AF "
        "FROM varInfo_synthetic "
        "WHERE gene_name = ? AND HighImpact = '1' "
        "  AND CADDphred != '.' AND CAST(CADDphred AS REAL) > ? "
        "ORDER BY CAST(CADDphred AS REAL) DESC",
        (gene, cadd_min)
    )


@mcp.tool()
def get_top_deleterious_in_gene(gene: str, top_n: int = 10) -> list[dict]:
    """
    Return the most deleterious variants in a gene.
    Definition: CADDphred > 20 AND SIFT = 'D' AND PolyPhen = 'D'.
    Always states this definition in the result.

    Args:
        gene:  Gene name
        top_n: Number of variants to return (default 10)
    """
    return _query(
        "SELECT VAR_id, gene_name, CADDphred, SIFT, PolyPhen, AF, "
        "  'CADDphred>20 AND SIFT=D AND PolyPhen=D' AS definition_used "
        "FROM varInfo_synthetic "
        "WHERE gene_name = ? AND CADDphred != '.' "
        "  AND CAST(CADDphred AS REAL) > 20 "
        "  AND SIFT = 'D' AND PolyPhen = 'D' "
        "ORDER BY CAST(CADDphred AS REAL) DESC "
        f"LIMIT {int(top_n)}",
        (gene,)
    )


@mcp.tool()
def count_sift_deleterious_in_gene(gene: str) -> list[dict]:
    """
    Count variants in a gene predicted deleterious by SIFT (SIFT = 'D').

    Args:
        gene: Gene name
    """
    return _query(
        "SELECT COUNT(*) AS n_sift_deleterious, gene_name "
        "FROM varInfo_synthetic "
        "WHERE gene_name = ? AND SIFT = 'D'",
        (gene,)
    )


@mcp.tool()
def get_highest_af_variant() -> list[dict]:
    """
    Return the variant with the highest global allele frequency.
    Uses ORDER BY DESC LIMIT 1 — never uses WHERE AF = MAX(AF).
    """
    return _query(
        "SELECT VAR_id, gene_name, CHROM, POS, REF, ALT, AF, "
        "       HighImpact, ModerateImpact, CADDphred "
        "FROM varInfo_synthetic "
        "WHERE AF != '.' "
        "ORDER BY CAST(AF AS REAL) DESC "
        "LIMIT 1"
    )


@mcp.tool()
def get_average_af_by_impact() -> list[dict]:
    """
    Average allele frequency separately for synonymous, moderate, and high-impact variants.
    Uses CASE WHEN to compute three separate averages in one query.
    """
    return _query(
        "SELECT "
        "  AVG(CASE WHEN Synonymous='1' THEN CAST(AF AS REAL) END) AS avg_AF_synonymous, "
        "  AVG(CASE WHEN ModerateImpact='1' THEN CAST(AF AS REAL) END) AS avg_AF_moderate, "
        "  AVG(CASE WHEN HighImpact='1' THEN CAST(AF AS REAL) END) AS avg_AF_high "
        "FROM varInfo_synthetic WHERE AF != '.'"
    )


@mcp.tool()
def summarize_variants_by_gene(min_variants: int = 10,
                                order_by: str = "total_variants") -> list[dict]:
    """
    Summary table per gene: variant counts, impact breakdown, mean AF, genomic span.
    Only includes genes with more than min_variants variants.

    Args:
        min_variants: Minimum variant count to include (default 10)
        order_by:     Sort column: total_variants, high_impact_count,
                      moderate_impact_count, mean_AF, or length (default total_variants)
    """
    allowed = {"total_variants", "high_impact_count", "moderate_impact_count", "mean_AF", "length"}
    if order_by not in allowed:
        order_by = "total_variants"
    return _query(
        "SELECT gene_name, CHROM, "
        "  COUNT(*) AS total_variants, "
        "  SUM(CASE WHEN HighImpact='1' THEN 1 ELSE 0 END) AS high_impact_count, "
        "  SUM(CASE WHEN ModerateImpact='1' THEN 1 ELSE 0 END) AS moderate_impact_count, "
        "  SUM(CASE WHEN Synonymous='1' THEN 1 ELSE 0 END) AS synonymous_count, "
        "  ROUND(AVG(CASE WHEN AF != '.' THEN CAST(AF AS REAL) END), 8) AS mean_AF, "
        "  MIN(POS) AS start_pos, MAX(POS) AS end_pos, "
        "  (MAX(CAST(POS AS INTEGER)) - MIN(CAST(POS AS INTEGER))) AS length "
        "FROM varInfo_synthetic "
        "GROUP BY gene_name, CHROM "
        f"HAVING total_variants > {int(min_variants)} "
        f"ORDER BY {order_by} DESC"
    )



@mcp.tool()
def get_als_carrier_stats() -> list[dict]:
    """
    Count how many variants are carried by at least one ALS patient,
    and what percentage of all variants this represents.
    Also counts variants exclusive to ALS (not in any control).

    Genotype encoding: 0=hom-ref, 1=heterozygous, 2=homozygous alt.
    A carrier has genotype > 0.
    """
    return _query(
        "SELECT "
        "  COUNT(*) AS total_variants, "
        "  SUM(CASE WHEN (ALS_1>0 OR ALS_2>0 OR ALS_3>0 OR ALS_4>0 OR ALS_5>0) "
        "      THEN 1 ELSE 0 END) AS carried_by_als, "
        "  SUM(CASE WHEN (ALS_1>0 OR ALS_2>0 OR ALS_3>0 OR ALS_4>0 OR ALS_5>0) "
        "      AND Control_1=0 AND Control_2=0 AND Control_3=0 "
        "      AND Control_4=0 AND Control_5=0 "
        "      THEN 1 ELSE 0 END) AS als_only, "
        "  ROUND(100.0 * SUM(CASE WHEN (ALS_1>0 OR ALS_2>0 OR ALS_3>0 OR ALS_4>0 OR ALS_5>0) "
        "      THEN 1 ELSE 0 END) / COUNT(*), 2) AS pct_carried_by_als "
        "FROM varInfo_synthetic"
    )

@mcp.tool()
def run_variant_query(sql: str) -> list[dict]:
    """
    Execute a free-form SELECT query against varInfo_synthetic or varInfo.
    Use when the specialised tools above don't cover the question.

    SCHEMA — varInfo_synthetic columns:
      VAR_id, CHROM, POS, ID, REF, ALT, QUAL, FILTER, AC, AN,
      AF (global allele frequency — TEXT, may be '.'),
      gene_name, HighImpact (TEXT '0'/'1'), ModerateImpact (TEXT '0'/'1'),
      Synonymous (TEXT '0'/'1'),
      CADDphred (TEXT, '.' for missing), SIFT ('D'=deleterious, 'T'=tolerated, '.'=missing),
      PolyPhen ('D'=damaging, 'P'=possibly, 'B'=benign, '.'=missing),
      ALS_1..ALS_5 (INTEGER genotypes: 0=hom-ref, 1=het, 2=hom-alt),
      Control_1..Control_5 (INTEGER genotypes)

    RULES:
      - NEVER use IS NOT NULL for CADDphred/SIFT/PolyPhen — use != '.' instead
      - Use CAST(CADDphred AS REAL) for numeric comparisons
      - HighImpact/ModerateImpact/Synonymous are stored as TEXT '0' or '1'

    Args:
        sql: A valid SQLite SELECT statement
    """
    return _query(sql)


if __name__ == "__main__":
    mcp.run(transport="stdio")
