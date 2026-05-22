import sqlite3
import os
from mcp.server.fastmcp import FastMCP

# ── Database path ─────────────────────────────────────────────────────────────
# Reads RVAT_GDB_PATH from environment if set by start_services.sh,
# otherwise falls back to the default path.
DB_PATH = os.path.expanduser(
    os.environ.get("RVAT_GDB_PATH", "~/project_ALS_databse/references/rvatData.gdb")
)

mcp = FastMCP("rvatData")


def get_con():
    con = sqlite3.connect(DB_PATH)
    con.row_factory = sqlite3.Row
    return con


# ══════════════════════════════════════════════════════════════════════════════
# SCHEMA / EXPLORATION TOOLS
# ══════════════════════════════════════════════════════════════════════════════

@mcp.tool()
def list_tables() -> list[str]:
    """
    List all tables in the rvatData genomic database.
    Call this first if you are unsure which tables are available.
    """
    con = get_con()
    rows = con.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()
    con.close()
    return [r["name"] for r in rows]


@mcp.tool()
def describe_table(table_name: str) -> list[dict]:
    """
    Describe the columns of a table: name, type, and whether null is allowed.
    Use this to understand what a table contains before writing a query.
    """
    con = get_con()
    rows = con.execute(f"PRAGMA table_info({table_name})").fetchall()
    con.close()
    return [{"name": r["name"], "type": r["type"], "notnull": r["notnull"]} for r in rows]


@mcp.tool()
def get_sample_rows(table_name: str, n: int = 5) -> list[dict]:
    """
    Return a small sample of rows from a table.
    Useful to explore what data looks like before writing a query.
    """
    con = get_con()
    rows = con.execute(f"SELECT * FROM {table_name} LIMIT {n}").fetchall()
    con.close()
    return [dict(r) for r in rows]


# ══════════════════════════════════════════════════════════════════════════════
# GENERIC QUERY TOOLS
# ══════════════════════════════════════════════════════════════════════════════

@mcp.tool()
def run_query(sql: str) -> list[dict]:
    """
    Execute a read-only SELECT query on the rvatData SQLite database.
    Returns at most 200 rows. Only SELECT statements are allowed.

    DATABASE SCHEMA:
    - varInfo_synthetic: main table for variant analysis. Contains:
        VAR_id, CHROM, POS, ID, REF, ALT, QUAL, FILTER, AC, AN, AF (allele frequency),
        gene_name, HighImpact (0/1), ModerateImpact (0/1), Synonymous (0/1),
        CADDphred (deleteriousness score, higher = more deleterious),
        PolyPhen ('D'=damaging, 'P'=possibly damaging, 'B'=benign),
        SIFT ('D'=deleterious, 'T'=tolerated),
        ALS_1 through ALS_5 (genotypes for 5 ALS patients),
        Control_1 through Control_5 (genotypes for 5 controls).
        Genotype values: 0 = homozygous reference, 1 = heterozygous, 2 = homozygous alt.
        Missing values for CADDphred, PolyPhen, SIFT are stored as '.' not NULL.

    - varInfo: same structure as varInfo_synthetic but without genotype columns.
    - var: raw variant table (VAR_id, CHROM, POS, ID, REF, ALT, QUAL, FILTER, INFO, FORMAT).
    - pheno: sample phenotype table (IID, sex, pheno, pop, superPop, PC1-PC4, age).
    - SM: sample metadata (IID, sex).
    - meta: database metadata (rvatVersion, genomeBuild). Genome build is GRCh38.
    """
    if not sql.strip().upper().startswith("SELECT"):
        raise ValueError("Only SELECT queries are allowed.")
    con = get_con()
    rows = con.execute(sql).fetchmany(200)
    con.close()
    return [dict(r) for r in rows]


@mcp.tool()
def query_variants(sql: str) -> list[dict]:
    """
    Alias for run_query — used by the benchmark pipeline for custom SELECT queries.
    Execute a read-only SELECT query. Returns at most 200 rows.
    """
    return run_query(sql)


# ══════════════════════════════════════════════════════════════════════════════
# SPECIALISED VARIANT TOOLS
# ══════════════════════════════════════════════════════════════════════════════

@mcp.tool()
def get_variants_by_gene(gene: str, limit: int = 200) -> list[dict]:
    """
    Return all variants for a specific gene from varInfo_synthetic.
    Use limit=500 or higher for count questions.

    Args:
        gene:  Gene name, e.g. 'NEK1', 'SOD1', 'C9orf72'
        limit: Maximum number of rows (default 200)
    """
    con = get_con()
    rows = con.execute(
        "SELECT * FROM varInfo_synthetic WHERE gene_name = ? LIMIT ?",
        (gene, limit)
    ).fetchall()
    con.close()
    return [dict(r) for r in rows]


@mcp.tool()
def count_variants_by_gene(top_n: int = 20) -> list[dict]:
    """
    Count the number of variants per gene and return the top N genes.

    Args:
        top_n: Number of genes to return (default 20)
    """
    con = get_con()
    rows = con.execute(
        """SELECT gene_name,
                  COUNT(*) AS n_variants,
                  SUM(HighImpact) AS n_high,
                  SUM(ModerateImpact) AS n_moderate,
                  SUM(Synonymous) AS n_synonymous
           FROM varInfo_synthetic
           GROUP BY gene_name
           ORDER BY n_variants DESC
           LIMIT ?""",
        (top_n,)
    ).fetchall()
    con.close()
    return [dict(r) for r in rows]


@mcp.tool()
def get_variants_by_impact(impact: str, limit: int = 100) -> list[dict]:
    """
    Return variants filtered by impact level.

    Args:
        impact: 'HIGH' or 'MODERATE'
        limit:  Maximum number of rows (default 100)
    """
    impact_upper = impact.strip().upper()
    if impact_upper == "HIGH":
        col = "HighImpact"
    elif impact_upper == "MODERATE":
        col = "ModerateImpact"
    else:
        raise ValueError("impact must be 'HIGH' or 'MODERATE'.")

    con = get_con()
    rows = con.execute(
        f"""SELECT VAR_id, CHROM, POS, REF, ALT, gene_name,
                   HighImpact, ModerateImpact, CADDphred, SIFT, PolyPhen, AF
            FROM varInfo_synthetic
            WHERE {col} = 1
            ORDER BY CADDphred DESC
            LIMIT ?""",
        (limit,)
    ).fetchall()
    con.close()
    return [dict(r) for r in rows]


@mcp.tool()
def get_deleterious_variants(predictor: str = "SIFT", limit: int = 100) -> list[dict]:
    """
    Return harmful variants based on SIFT or PolyPhen prediction.

    Args:
        predictor: 'SIFT' (D=deleterious) or 'PolyPhen' (D=damaging)
        limit:     Maximum number of rows (default 100)
    """
    pred_upper = predictor.strip().upper()
    if pred_upper == "SIFT":
        where = "SIFT = 'D'"
    elif pred_upper == "POLYPHEN":
        where = "PolyPhen = 'D'"
    else:
        raise ValueError("predictor must be 'SIFT' or 'PolyPhen'.")

    con = get_con()
    rows = con.execute(
        f"""SELECT VAR_id, CHROM, POS, REF, ALT, gene_name,
                   CADDphred, SIFT, PolyPhen, HighImpact, ModerateImpact, AF
            FROM varInfo_synthetic
            WHERE {where}
            ORDER BY CADDphred DESC
            LIMIT ?""",
        (limit,)
    ).fetchall()
    con.close()
    return [dict(r) for r in rows]


@mcp.tool()
def summarize_database() -> dict:
    """
    Return summary statistics of the varInfo_synthetic table.
    Use this for an overview or database summary.
    """
    con = get_con()
    total   = con.execute("SELECT COUNT(*) FROM varInfo_synthetic").fetchone()[0]
    n_genes = con.execute("SELECT COUNT(DISTINCT gene_name) FROM varInfo_synthetic").fetchone()[0]
    n_high  = con.execute("SELECT COUNT(*) FROM varInfo_synthetic WHERE HighImpact = 1").fetchone()[0]
    n_mod   = con.execute("SELECT COUNT(*) FROM varInfo_synthetic WHERE ModerateImpact = 1").fetchone()[0]
    n_syn   = con.execute("SELECT COUNT(*) FROM varInfo_synthetic WHERE Synonymous = 1").fetchone()[0]
    n_sift  = con.execute("SELECT COUNT(*) FROM varInfo_synthetic WHERE SIFT = 'D'").fetchone()[0]
    n_pp    = con.execute("SELECT COUNT(*) FROM varInfo_synthetic WHERE PolyPhen = 'D'").fetchone()[0]
    avg_af  = con.execute("SELECT ROUND(AVG(AF), 6) FROM varInfo_synthetic").fetchone()[0]
    con.close()
    return {
        "total_variants":       total,
        "unique_genes":         n_genes,
        "high_impact":          n_high,
        "moderate_impact":      n_mod,
        "synonymous":           n_syn,
        "sift_deleterious":     n_sift,
        "polyphen_damaging":    n_pp,
        "mean_allele_freq":     avg_af,
        "database_path":        DB_PATH,
        "genome_build":         "GRCh38",
    }


# ══════════════════════════════════════════════════════════════════════════════
# CARRIER ANALYSIS TOOLS
# ══════════════════════════════════════════════════════════════════════════════

@mcp.tool()
def get_carriers_by_gene(gene: str, group: str = "ALS") -> list[dict]:
    """
    Return variants in a gene where at least one person in the given group
    is a carrier (genotype > 0).

    Args:
        gene:  Gene name, e.g. 'NEK1'
        group: 'ALS' or 'Control'
    """
    group_upper = group.strip().upper()
    if group_upper == "ALS":
        cols = ["ALS_1", "ALS_2", "ALS_3", "ALS_4", "ALS_5"]
    elif group_upper == "CONTROL":
        cols = ["Control_1", "Control_2", "Control_3", "Control_4", "Control_5"]
    else:
        raise ValueError("group must be 'ALS' or 'Control'.")

    carrier_filter = " OR ".join([f"{c} > 0" for c in cols])
    con = get_con()
    rows = con.execute(
        f"""SELECT VAR_id, CHROM, POS, REF, ALT, gene_name,
                   CADDphred, SIFT, PolyPhen, HighImpact,
                   ALS_1, ALS_2, ALS_3, ALS_4, ALS_5,
                   Control_1, Control_2, Control_3, Control_4, Control_5
            FROM varInfo_synthetic
            WHERE gene_name = ? AND ({carrier_filter})""",
        (gene,)
    ).fetchall()
    con.close()
    return [dict(r) for r in rows]


if __name__ == "__main__":
    mcp.run()
