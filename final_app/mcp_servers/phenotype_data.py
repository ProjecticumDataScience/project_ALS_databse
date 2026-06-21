#!/usr/bin/env python3
# ══════════════════════════════════════════════════════════════════════════════
# phenotype_data.py — Sample phenotype and population tools
# Covers: sex distribution, age, population, cohort, and
#         joins between pheno/SM and varInfo_synthetic genotype columns.
#
# KEY MAPPING: genotype columns → pheno IIDs
#   ALS_1 → 'ALS1', ALS_2 → 'ALS2', ..., Control_1 → 'Control1', etc.
#   Control columns map to CTRL1..CTRL5 in the pheno table (NOT 'Control1')
#
# CODING:
#   pheno.sex:   1 = female, 2 = male
#   pheno.pheno: 1 = ALS case, 2 = control
#
# NOTE: This tool's _IID_TO_COL mapping is scoped to the SYNTHETIC 10-sample
# genotype subset only (5 ALS + 5 control). For carrier questions involving
# the real 25,000-sample cohort (e.g. population/sex-filtered pathogenic
# carrier counts), use rvat_analysis/get_carrier_count_filtered instead —
# see pipeline.R's router disambiguation rules for when to use which.
# ══════════════════════════════════════════════════════════════════════════════
import os
import sqlite3
import pathlib
from mcp.server.fastmcp import FastMCP

_script_dir = pathlib.Path(__file__).parent.resolve()
DB_PATH = os.path.expanduser(
    os.environ.get("RVAT_GDB_PATH", str(_script_dir.parent / "rvatData.gdb"))
)

mcp = FastMCP("phenotype_data")


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


## IID ↔ genotype column mapping
_IID_TO_COL = {
    "ALS1": "ALS_1", "ALS2": "ALS_2", "ALS3": "ALS_3",
    "ALS4": "ALS_4", "ALS5": "ALS_5",
    "CTRL1": "Control_1", "CTRL2": "Control_2",
    "CTRL3": "Control_3", "CTRL4": "Control_4", "CTRL5": "Control_5",
}


@mcp.tool()
def get_sex_distribution() -> list[dict]:
    """
    Get the sex distribution of all samples in the dataset.
    sex coding: 1 = female, 2 = male.
    pheno coding: 1 = ALS case, 2 = control.
    """
    return _query(
        "SELECT "
        "  CASE CAST(sex AS INTEGER) WHEN 1 THEN 'Female' WHEN 2 THEN 'Male' ELSE 'Unknown' END AS sex, "
        "  COUNT(*) AS n_samples, "
        "  SUM(CASE WHEN pheno = 1 THEN 1 ELSE 0 END) AS n_cases, "
        "  SUM(CASE WHEN pheno = 2 THEN 1 ELSE 0 END) AS n_controls "
        "FROM pheno "
        "GROUP BY CAST(sex AS INTEGER)"
    )


@mcp.tool()
def get_population_counts() -> list[dict]:
    """
    Count samples per population from the pheno table.
    Returns pop, superPop, total count, and breakdown by sex and phenotype.
    """
    return _query(
        "SELECT pop, superPop, "
        "  COUNT(*) AS n_samples, "
        "  SUM(CASE WHEN CAST(sex AS INTEGER) = 1 THEN 1 ELSE 0 END) AS n_female, "
        "  SUM(CASE WHEN CAST(sex AS INTEGER) = 2 THEN 1 ELSE 0 END) AS n_male, "
        "  SUM(CASE WHEN pheno = 1 THEN 1 ELSE 0 END) AS n_cases, "
        "  SUM(CASE WHEN pheno = 2 THEN 1 ELSE 0 END) AS n_controls "
        "FROM pheno "
        "GROUP BY pop, superPop "
        "ORDER BY n_samples DESC"
    )


@mcp.tool()
def get_sample_phenotypes(iid: str = None) -> list[dict]:
    """
    Return phenotype information for samples.
    Can return all samples or a specific one by IID.

    Args:
        iid: Sample ID, e.g. 'ALS1', 'Control3'. If None, returns all.
    """
    if iid:
        return _query("SELECT * FROM pheno WHERE IID = ?", (iid,))
    return _query("SELECT * FROM pheno ORDER BY pheno, IID")


@mcp.tool()
def get_carriers_with_phenotype(gene: str,
                                 impact: str = "any",
                                 sex: int = None,
                                 population: str = None) -> list[dict]:
    """
    Find carriers of variants in a specific gene and join with their phenotype data.
    This is the key multi-table tool — links genotype columns to pheno table.

    SCOPE: covers only the SYNTHETIC 10-sample subset (5 ALS, 5 control) in
    varInfo_synthetic. Use this for plain "female/male carriers in [gene]"
    questions with NO mention of "pathogenic" or impact level. For questions
    that explicitly say "pathogenic mutation" or name an impact level, use
    rvat_analysis/get_carrier_count_filtered instead — it covers the real
    25,000-sample cohort.

    IID mapping: ALS_1 column → IID 'ALS1', Control_3 column → IID 'Control3'.
    sex coding: 1 = female, 2 = male.

    Args:
        gene:       Gene name, e.g. 'SOD1'
        impact:     Impact filter: 'HIGH', 'MODERATE', 'any' (default: 'any')
        sex:        Optional sex filter: 1 (female) or 2 (male). None = all.
        population: Optional population filter, e.g. 'SAS', 'EUR'. None = all.
    """
    impact_map = {
        "HIGH":     "v.HighImpact = '1'",
        "MODERATE": "v.ModerateImpact = '1'",
        "ANY":      "(v.HighImpact = '1' OR v.ModerateImpact = '1')",
    }
    impact_filter = impact_map.get(impact.upper(), "(v.HighImpact = '1' OR v.ModerateImpact = '1')")

    con = get_con()
    try:
        results = []
        for iid, col in _IID_TO_COL.items():
            ## Check if this sample carries any qualifying variants
            cur = con.execute(
                f"SELECT COUNT(*) AS n "
                f"FROM varInfo_synthetic v "
                f"WHERE v.gene_name = ? AND {impact_filter} AND v.{col} > 0",
                (gene,)
            )
            n = cur.fetchone()["n"]
            if n == 0:
                continue

            ## Get phenotype for this sample
            pheno_row = con.execute(
                "SELECT IID, CAST(sex AS INTEGER) AS sex, pheno, pop, superPop, age "
                "FROM pheno WHERE IID = ?", (iid,)
            ).fetchone()

            if pheno_row is None:
                continue

            ## Apply optional filters
            if sex is not None and pheno_row["sex"] != sex:
                continue
            if population is not None and pheno_row["superPop"] != population.upper():
                continue

            results.append({
                "IID":               iid,
                "genotype_column":   col,
                "sex":               pheno_row["sex"],
                "sex_label":         "Female" if pheno_row["sex"] == 1 else "Male",
                "phenotype":         pheno_row["pheno"],
                "phenotype_label":   "ALS" if pheno_row["pheno"] == 1 else "Control",
                "population":        pheno_row["pop"],
                "super_population":  pheno_row["superPop"],
                "age":               pheno_row["age"],
                "n_qualifying_variants": n,
            })

        return results if results else [{"message": f"No qualifying carriers found for {gene} ({impact})"}]
    finally:
        con.close()


@mcp.tool()
def get_age_distribution() -> list[dict]:
    """
    Return age statistics for ALS cases and controls.
    Note: age is available in the pheno table but NOT linked to genotypes by name.
    """
    return _query(
        "SELECT "
        "  CASE pheno WHEN 1 THEN 'ALS case' WHEN 2 THEN 'Control' END AS group_label, "
        "  COUNT(*) AS n_samples, "
        "  ROUND(AVG(age), 2) AS mean_age, "
        "  ROUND(MIN(age), 2) AS min_age, "
        "  ROUND(MAX(age), 2) AS max_age "
        "FROM pheno "
        "WHERE age IS NOT NULL "
        "GROUP BY pheno"
    )


@mcp.tool()
def run_phenotype_query(sql: str) -> list[dict]:
    """
    Execute a free-form SELECT query against pheno or SM tables.
    Use when the specialised tools above don't cover the question.

    SCHEMA:
      pheno: IID (TEXT), sex (REAL: 1=female 2=male), pheno (INTEGER: 1=ALS 2=control),
             pop (TEXT), superPop (TEXT), PC1-PC4 (REAL), age (REAL)
      SM:    IID (TEXT), sex (INTEGER)

    IID mapping: ALS_1 column in varInfo_synthetic = IID 'ALS1' in pheno.

    Args:
        sql: A valid SQLite SELECT statement
    """
    return _query(sql)


if __name__ == "__main__":
    mcp.run(transport="stdio")