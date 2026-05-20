import sqlite3
import os
from mcp.server.fastmcp import FastMCP

# ── Database pad ─────────────────────────────────────────────────────────────
# Leest RVAT_GDB_PATH uit de omgeving als die gezet is (door start_services.sh),
# anders valt het terug op het standaard pad.
DB_PATH = os.path.expanduser(
    os.environ.get("RVAT_GDB_PATH", "~/project_ALS_databse/rvatData.gdb")
)

mcp = FastMCP("rvatData")


def get_con():
    con = sqlite3.connect(DB_PATH)
    con.row_factory = sqlite3.Row
    return con


# ══════════════════════════════════════════════════════════════════════════════
# SCHEMA / EXPLORATIE TOOLS
# ══════════════════════════════════════════════════════════════════════════════

@mcp.tool()
def list_tables() -> list[str]:
    """
    Lijst alle tabellen in de rvatData genomische database.
    Roep dit eerst aan als je niet zeker weet welke tabellen beschikbaar zijn.
    """
    con = get_con()
    rows = con.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()
    con.close()
    return [r["name"] for r in rows]


@mcp.tool()
def describe_table(table_name: str) -> list[dict]:
    """
    Beschrijf de kolommen van een tabel: naam, type en of null toegestaan is.
    Gebruik dit om te begrijpen wat een tabel bevat vóór je een query uitvoert.
    """
    con = get_con()
    rows = con.execute(f"PRAGMA table_info({table_name})").fetchall()
    con.close()
    return [{"name": r["name"], "type": r["type"], "notnull": r["notnull"]} for r in rows]


@mcp.tool()
def get_sample_rows(table_name: str, n: int = 5) -> list[dict]:
    """
    Geef een kleine steekproef van rijen uit een tabel.
    Handig om te verkennen hoe data eruit ziet vóór je een query schrijft.
    """
    con = get_con()
    rows = con.execute(f"SELECT * FROM {table_name} LIMIT {n}").fetchall()
    con.close()
    return [dict(r) for r in rows]


# ══════════════════════════════════════════════════════════════════════════════
# GENERIEKE QUERY TOOLS
# ══════════════════════════════════════════════════════════════════════════════

@mcp.tool()
def run_query(sql: str) -> list[dict]:
    """
    Voer een read-only SELECT query uit op de rvatData SQLite database.
    Maximaal 200 rijen worden teruggegeven. Alleen SELECT statements zijn toegestaan.

    DATABASE SCHEMA:
    - varInfo_synthetic: hoofdtabel voor variant-analyse. Bevat:
        VAR_id, CHROM, POS, ID, REF, ALT, QUAL, FILTER, AC, AN, AF (allelfrequentie),
        gene_name, HighImpact (0/1), ModerateImpact (0/1), Synonymous (0/1),
        CADDphred (deleteriousness score, hoger = schadelijker),
        PolyPhen ('D'=damaging, 'P'=possibly damaging, 'B'=benign),
        SIFT ('D'=deleterious, 'T'=tolerated),
        ALS_1 t/m ALS_5 (genotypen voor 5 ALS-patiënten),
        Control_1 t/m Control_5 (genotypen voor 5 controles).
        Genotypewaarden: 0 = homozygoot referentie, 1 = heterozygoot, 2 = homozygoot alternatief.

    - varInfo: zelfde structuur als varInfo_synthetic maar zonder genotypekolommen.
    - var: ruwe variant tabel (VAR_id, CHROM, POS, ID, REF, ALT, QUAL, FILTER, INFO, FORMAT).
    - pheno: steekproef fenotype tabel (IID, sex, pheno, pop, superPop, PC1-PC4, age).
    - SM: steekproef metadata (IID, sex).
    - meta: database metadata (rvatVersion, genomeBuild). Genomebuild is GRCh38.
    """
    if not sql.strip().upper().startswith("SELECT"):
        raise ValueError("Alleen SELECT queries zijn toegestaan.")
    con = get_con()
    rows = con.execute(sql).fetchmany(200)
    con.close()
    return [dict(r) for r in rows]


@mcp.tool()
def query_variants(sql: str) -> list[dict]:
    """
    Alias voor run_query — gebruikt door de Shiny app voor aangepaste SELECT queries.
    Voer een read-only SELECT query uit. Maximaal 200 rijen.
    """
    return run_query(sql)


# ══════════════════════════════════════════════════════════════════════════════
# GESPECIALISEERDE VARIANT TOOLS
# ══════════════════════════════════════════════════════════════════════════════

@mcp.tool()
def get_variants_by_gene(gene: str, limit: int = 200) -> list[dict]:
    """
    Geef alle varianten voor een specifiek gen uit varInfo_synthetic.
    Gebruik limit=500 of hoger voor telvragen.

    Args:
        gene:  Gennaam, bijv. 'NEK1', 'SOD1', 'C9orf72'
        limit: Maximum aantal rijen (standaard 200)
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
    Tel het aantal varianten per gen en geef de top N genen terug.

    Args:
        top_n: Aantal terug te geven genen (standaard 20)
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
    Geef varianten gefilterd op impactniveau.

    Args:
        impact: 'HIGH' of 'MODERATE'
        limit:  Maximum aantal rijen (standaard 100)
    """
    impact_upper = impact.strip().upper()
    if impact_upper == "HIGH":
        col = "HighImpact"
    elif impact_upper == "MODERATE":
        col = "ModerateImpact"
    else:
        raise ValueError("impact moet 'HIGH' of 'MODERATE' zijn.")

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
    Geef schadelijke varianten op basis van SIFT of PolyPhen voorspelling.

    Args:
        predictor: 'SIFT' (D=deleterious) of 'PolyPhen' (D=damaging)
        limit:     Maximum aantal rijen (standaard 100)
    """
    pred_upper = predictor.strip().upper()
    if pred_upper == "SIFT":
        where = "SIFT = 'D'"
    elif pred_upper == "POLYPHEN":
        where = "PolyPhen = 'D'"
    else:
        raise ValueError("predictor moet 'SIFT' of 'PolyPhen' zijn.")

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
    Geef samenvattende statistieken van de varInfo_synthetic tabel.
    Gebruik dit voor een overzicht of database-samenvatting.
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
        "totaal_varianten":       total,
        "unieke_genen":           n_genes,
        "high_impact":            n_high,
        "moderate_impact":        n_mod,
        "synonymous":             n_syn,
        "sift_deleterious":       n_sift,
        "polyphen_damaging":      n_pp,
        "gemiddelde_allelfreq":   avg_af,
        "database_pad":           DB_PATH,
        "genome_build":           "GRCh38",
    }


# ══════════════════════════════════════════════════════════════════════════════
# CARRIER ANALYSE TOOLS
# ══════════════════════════════════════════════════════════════════════════════

@mcp.tool()
def get_carriers_by_gene(gene: str, group: str = "ALS") -> list[dict]:
    """
    Geef varianten in een gen waarbij minstens één persoon in de opgegeven groep
    drager is (genotype > 0).

    Args:
        gene:  Gennaam, bijv. 'NEK1'
        group: 'ALS' of 'Control'
    """
    group_upper = group.strip().upper()
    if group_upper == "ALS":
        cols = ["ALS_1", "ALS_2", "ALS_3", "ALS_4", "ALS_5"]
    elif group_upper == "CONTROL":
        cols = ["Control_1", "Control_2", "Control_3", "Control_4", "Control_5"]
    else:
        raise ValueError("group moet 'ALS' of 'Control' zijn.")

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
