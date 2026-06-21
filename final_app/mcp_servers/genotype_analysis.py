#!/usr/bin/env python3
# ══════════════════════════════════════════════════════════════════════════════
# genotype_analysis.py — Carrier analysis and burden tools
# Covers: carrier counts, burden, case vs control, homozygous, dosage ratio.
# Uses varInfo_synthetic genotype columns (ALS_1..5, Control_1..5).
# Genotype encoding: 0=hom-ref, 1=heterozygous, 2=homozygous alt (carrier)
# ══════════════════════════════════════════════════════════════════════════════
import os
import sqlite3
import pathlib
from mcp.server.fastmcp import FastMCP

_script_dir = pathlib.Path(__file__).parent.resolve()
DB_PATH = os.path.expanduser(
    os.environ.get("RVAT_GDB_PATH", str(_script_dir.parent / "rvatData.gdb"))
)

mcp = FastMCP("genotype_analysis")


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


## Sample columns for reference
_ALS_COLS     = ["ALS_1", "ALS_2", "ALS_3", "ALS_4", "ALS_5"]
_CONTROL_COLS = ["Control_1", "Control_2", "Control_3", "Control_4", "Control_5"]
_ALL_COLS     = _ALS_COLS + _CONTROL_COLS


@mcp.tool()
def get_carriers_by_gene(gene: str, group: str = "ALS") -> list[dict]:
    """
    Return variants in a gene where at least one person in the group is a carrier
    (genotype > 0, meaning heterozygous or homozygous alt).

    Args:
        gene:  Gene name, e.g. 'NEK1', 'SOD1'
        group: 'ALS', 'Control', or 'all' (default: 'ALS')
    """
    group_upper = group.strip().upper()
    if group_upper == "ALS":
        cols = _ALS_COLS
    elif group_upper == "CONTROL":
        cols = _CONTROL_COLS
    else:
        cols = _ALL_COLS

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
def get_high_impact_homozygous_ALS() -> list[dict]:
    """
    Return high-impact variants where at least one ALS patient is homozygous
    (genotype = 2 means homozygous alt).
    """
    return _query(
        "SELECT VAR_id, gene_name, HighImpact, CADDphred, "
        "       ALS_1, ALS_2, ALS_3, ALS_4, ALS_5 "
        "FROM varInfo_synthetic "
        "WHERE HighImpact = '1' "
        "  AND (ALS_1 = 2 OR ALS_2 = 2 OR ALS_3 = 2 OR ALS_4 = 2 OR ALS_5 = 2)"
    )


@mcp.tool()
def get_sample_burden(sample_id: str = None, impact: str = "ALL", group: str = "all") -> list[dict]:
    """
    Return carrier burden (heterozygous/homozygous/total counts) for samples.

    THIS IS THE ONLY TOOL NEEDED for any "which sample has the most/highest/
    lowest [burden/homozygous calls/variants]" question, AND for "how many
    variants does sample X carry" questions — both shapes are covered by
    the same tool, just with or without sample_id set.

    Args:
        sample_id: Optional. A specific sample e.g. 'ALS_1', 'Control_3'.
                   If given, returns ONE row for that sample only.
                   If omitted (None), returns ALL samples, one row each —
                   use this for "which sample has the most/highest X" questions.
        impact:    'HIGH', 'MODERATE', 'SYNONYMOUS', or 'ALL' (default: 'ALL' —
                   most burden questions mean ALL variants unless a specific
                   impact level is explicitly named)
        group:     Only used when sample_id is None. 'ALS', 'Control', or 'all'
                   (default: 'all') — which samples to include.

    Returns:
        One row per sample with: sample_id, heterozygous, homozygous,
        total_carrier_variants, impact_filter. Sort/compare these columns
        yourself to answer "which sample has the most X" — do not call
        this tool once per sample.
    """
    allowed = [f"ALS_{i}" for i in range(1, 6)] + [f"Control_{i}" for i in range(1, 6)]

    impact_map = {
        "HIGH":       "HighImpact = '1'",
        "MODERATE":   "ModerateImpact = '1'",
        "SYNONYMOUS": "Synonymous = '1'",
        "ALL":        "1=1",
    }
    where = impact_map.get(impact.upper(), "1=1")

    if sample_id is not None:
        if sample_id not in allowed:
            raise ValueError(f"Unknown sample '{sample_id}'. Choose from: {', '.join(allowed)}")
        target_cols = [sample_id]
    else:
        group_upper = group.strip().upper()
        if group_upper == "ALS":
            target_cols = _ALS_COLS
        elif group_upper == "CONTROL":
            target_cols = _CONTROL_COLS
        else:
            target_cols = _ALL_COLS

    select_parts = ", ".join(
        f"'{c}' AS sample_id_{i}, "
        f"SUM(CASE WHEN {c} = 1 THEN 1 ELSE 0 END) AS het_{i}, "
        f"SUM(CASE WHEN {c} = 2 THEN 1 ELSE 0 END) AS hom_{i}, "
        f"SUM(CASE WHEN {c} > 0 THEN 1 ELSE 0 END) AS total_{i}"
        for i, c in enumerate(target_cols)
    )

    raw = _query(f"SELECT {select_parts} FROM varInfo_synthetic WHERE {where}")

    ## Reshape from one wide row into one row per sample for clean reading
    if not raw:
        return []
    wide = raw[0]
    rows = []
    for i, c in enumerate(target_cols):
        rows.append({
            "sample_id":              wide.get(f"sample_id_{i}", c),
            "heterozygous":           wide.get(f"het_{i}", 0),
            "homozygous":             wide.get(f"hom_{i}", 0),
            "total_carrier_variants": wide.get(f"total_{i}", 0),
            "impact_filter":          impact,
        })
    return rows


@mcp.tool()
def count_carriers_above_threshold(min_carriers: int,
                                    group: str = "ALS",
                                    impact: str = "ALL") -> list[dict]:
    """
    Count variants carried (het or hom, genotype > 0) by at least min_carriers
    individuals within a group. Correctly handles "at least N of 5" questions
    using proper combinatorial logic — sums carrier status across all relevant
    columns rather than nested OR/AND chains, which are easy to get wrong.

    Args:
        min_carriers: Minimum number of carriers required within the group (e.g. 3)
        group:        'ALS', 'Control', or 'all' (default: 'ALS')
        impact:       'HIGH', 'MODERATE', 'SYNONYMOUS', or 'ALL' (default: 'ALL')
    """
    group_upper = group.strip().upper()
    if group_upper == "ALS":
        cols = _ALS_COLS
    elif group_upper == "CONTROL":
        cols = _CONTROL_COLS
    else:
        cols = _ALL_COLS

    impact_map = {
        "HIGH":       "HighImpact = '1'",
        "MODERATE":   "ModerateImpact = '1'",
        "SYNONYMOUS": "Synonymous = '1'",
        "ALL":        "1=1",
    }
    where = impact_map.get(impact.upper(), "1=1")

    carrier_sum = " + ".join(f"CASE WHEN {c} > 0 THEN 1 ELSE 0 END" for c in cols)

    return _query(
        f"SELECT COUNT(*) AS n_variants "
        f"FROM ( "
        f"  SELECT VAR_id, ({carrier_sum}) AS n_carriers "
        f"  FROM varInfo_synthetic WHERE {where} "
        f") sub "
        f"WHERE n_carriers >= ?",
        (int(min_carriers),)
    )


@mcp.tool()
def get_total_burden_cases_vs_controls(gene: str = None) -> list[dict]:
    """
    Total allele burden (sum of genotype values) for ALS cases vs controls.
    Each allele copy contributes: het=1, hom-alt=2.

    NOTE: This returns GROUP TOTALS only (one number for all cases, one for
    all controls). For "which sample has the highest burden" questions, use
    get_sample_burden instead (call with no sample_id) — this tool cannot
    answer per-sample questions.

    Args:
        gene: Optional gene name to filter. If None, uses all variants.
    """
    where = f"WHERE gene_name = ?" if gene else ""
    params = (gene,) if gene else ()
    return _query(
        f"SELECT "
        f"  SUM(ALS_1+ALS_2+ALS_3+ALS_4+ALS_5) AS total_cases_burden, "
        f"  SUM(Control_1+Control_2+Control_3+Control_4+Control_5) AS total_controls_burden, "
        f"  SUM(ALS_1+ALS_2+ALS_3+ALS_4+ALS_5) - "
        f"    SUM(Control_1+Control_2+Control_3+Control_4+Control_5) AS difference "
        f"FROM varInfo_synthetic {where}",
        params
    )


@mcp.tool()
def get_dosage_ratio_by_gene(impact: str = "ALL") -> list[dict]:
    """
    For each gene, compute the case/control dosage ratio with Laplace smoothing.
    Formula: (case_burden + 1.0) / (control_burden + 1.0)
    Returns genes ordered by dosage ratio descending.
    Genes with ratio > 1 have more variant burden in cases than controls —
    these are the "enriched in cases" genes.

    Args:
        impact: 'HIGH', 'MODERATE', 'SYNONYMOUS', or 'ALL' (default: 'ALL').
                Use 'HIGH' for "high-impact variants only" style questions.
    """
    impact_map = {
        "HIGH":       "WHERE HighImpact = '1'",
        "MODERATE":   "WHERE ModerateImpact = '1'",
        "SYNONYMOUS": "WHERE Synonymous = '1'",
        "ALL":        "",
    }
    where = impact_map.get(impact.upper(), "")

    return _query(
        f"SELECT "
        f"  gene_name, "
        f"  SUM(ALS_1+ALS_2+ALS_3+ALS_4+ALS_5) AS case_burden, "
        f"  SUM(Control_1+Control_2+Control_3+Control_4+Control_5) AS control_burden, "
        f"  ROUND((SUM(ALS_1+ALS_2+ALS_3+ALS_4+ALS_5) + 1.0) / "
        f"        (SUM(Control_1+Control_2+Control_3+Control_4+Control_5) + 1.0), 4) "
        f"    AS dosage_ratio, "
        f"  CASE WHEN SUM(ALS_1+ALS_2+ALS_3+ALS_4+ALS_5) > SUM(Control_1+Control_2+Control_3+Control_4+Control_5) "
        f"       THEN 1 ELSE 0 END AS enriched_in_cases "
        f"FROM varInfo_synthetic {where} "
        f"GROUP BY gene_name "
        f"ORDER BY dosage_ratio DESC"
    )


@mcp.tool()
def get_case_enriched_variants(top_n: int = 10) -> list[dict]:
    """
    Return variants with the highest case/control allele count ratio.
    Useful for finding variants enriched in ALS patients vs controls.

    Args:
        top_n: Number of top variants to return (default 10)
    """
    return _query(
        "SELECT VAR_id, gene_name, "
        "  (ALS_1+ALS_2+ALS_3+ALS_4+ALS_5) AS case_count, "
        "  (Control_1+Control_2+Control_3+Control_4+Control_5) AS control_count, "
        "  ROUND(((ALS_1+ALS_2+ALS_3+ALS_4+ALS_5) * 1.0) / "
        "        NULLIF((Control_1+Control_2+Control_3+Control_4+Control_5), 0), 4) "
        "    AS case_control_ratio "
        "FROM varInfo_synthetic "
        "ORDER BY case_control_ratio DESC "
        f"LIMIT {int(top_n)}"
    )


@mcp.tool()
def get_pathogenic_burden_by_gene(sample_id: str = None) -> list[dict]:
    """
    For each gene, count pathogenic variants (CADDphred>20 OR PolyPhen='D' OR SIFT='D').
    Optionally filter to variants carried by a specific sample.

    Args:
        sample_id: Optional sample filter, e.g. 'ALS_1'. If None, counts all variants.
    """
    allowed = [f"ALS_{i}" for i in range(1, 6)] + [f"Control_{i}" for i in range(1, 6)]
    sample_filter = ""
    if sample_id is not None:
        if sample_id not in allowed:
            raise ValueError(f"Unknown sample '{sample_id}'. Choose from: {', '.join(allowed)}")
        sample_filter = f"AND {sample_id} > 0"

    return _query(
        f"SELECT gene_name, COUNT(*) AS pathogenic_variants "
        f"FROM varInfo_synthetic "
        f"WHERE ( "
        f"    (CADDphred != '.' AND CAST(CADDphred AS REAL) > 20) "
        f"    OR PolyPhen = 'D' OR SIFT = 'D' "
        f") {sample_filter} "
        f"GROUP BY gene_name "
        f"ORDER BY pathogenic_variants DESC"
    )


if __name__ == "__main__":
    mcp.run(transport="stdio")