#!/usr/bin/env python3
# ══════════════════════════════════════════════════════════════════════════════
# rvatData MCP Server — Python/SQLite implementatie (mirror van DBI/RSQLite)
# ══════════════════════════════════════════════════════════════════════════════
import os
import sqlite3
from typing import Any
from mcp.server.fastmcp import FastMCP

DB_PATH = os.path.expanduser(
    os.environ.get("RVAT_GDB_PATH", "~/project_ALS_databse/references/rvatData.gdb")
)

mcp = FastMCP("rvatData MCP Server")


# ─── Hulpfuncties ─────────────────────────────────────────────────────────────

def get_con():
    """Open een SQLite verbinding (read-only via URI)."""
    uri = f"file:{DB_PATH}?mode=ro"
    return sqlite3.connect(uri, uri=True)


def _query(sql: str, params: tuple = (), max_rows: int = 200) -> list[dict]:
    """Voer een veilige read-only SELECT query uit en geef max max_rows rijen."""
    if not sql.strip().upper().startswith("SELECT"):
        raise ValueError("Alleen SELECT queries zijn toegestaan.")
    con = get_con()
    try:
        con.row_factory = sqlite3.Row
        cur = con.execute(sql, params)
        rows = cur.fetchmany(max_rows)
        return [dict(r) for r in rows]
    finally:
        con.close()


def _scalar(sql: str, params: tuple = ()) -> Any:
    """Geef één scalaire waarde terug."""
    rows = _query(sql, params, max_rows=1)
    if rows:
        return list(rows[0].values())[0]
    return None


# ══════════════════════════════════════════════════════════════════════════════
# 1. SCHEMA / EXPLORATIE
# ══════════════════════════════════════════════════════════════════════════════

@mcp.tool()
def list_tables() -> list[str]:
    """Lijst alle tabellen in de database."""
    con = get_con()
    try:
        cur = con.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        return [r[0] for r in cur.fetchall()]
    finally:
        con.close()


@mcp.tool()
def describe_table(table_name: str) -> list[dict]:
    """
    Beschrijf de kolommen van een tabel (naam, type, notnull).

    Args:
        table_name: Naam van de tabel
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
    Geef de eerste n rijen van een tabel.

    Args:
        table_name: Naam van de tabel
        n: Aantal rijen (standaard 5)
    """
    return _query(f"SELECT * FROM {table_name} LIMIT {int(n)}")


# ══════════════════════════════════════════════════════════════════════════════
# 2. ALGEMENE QUERY TOOL
# ══════════════════════════════════════════════════════════════════════════════

@mcp.tool()
def run_query(sql: str) -> list[dict]:
    """
    Voer een willekeurige read-only SELECT query uit (max 200 rijen).

    BESCHIKBARE KOLOMMEN IN varInfo_synthetic:
      VAR_id, CHROM, POS, ID, REF, ALT, QUAL, FILTER,
      AC, AN, AF (globale allelfrequentie — GEEN populatie-specifieke AF),
      gene_name,
      HighImpact (0/1), ModerateImpact (0/1), Synonymous (0/1),
      CADDphred (hoog = schadelijker),
      SIFT  : 'D' = deleterious, 'T' = tolerated,
      PolyPhen: 'D' = probably damaging, 'P' = possibly damaging, 'B' = benign,
      ALS_1 .. ALS_5, Control_1 .. Control_5
        (genotype: 0 = hom-ref, 1 = heterozygoot, 2 = hom-alt)

    NIET BESCHIKBAAR:
      - Leeftijd van patiënten of controles
      - Pathogeniciteitsstatus (bijv. ClinVar)
      - Populatie-specifieke allelfrequenties (EUR, SAS, AFR)
      - Geslacht van de dragers
      - Eerdere publicaties of rapportages over varianten

    ONMOGELIJKE COMBINATIES:
      - Een variant kan NIET tegelijk Synonymous=1 EN HighImpact=1 zijn.

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
    Tel het aantal varianten in een gen.

    Args:
        gene: Gennaam, bijv. 'NEK1'
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
    Selecteer varianten in een gen met HighImpact en CADDphred boven een drempel.

    Args:
        gene: Gennaam
        cadd_min: Minimale CADDphred score (standaard 20)
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
    Tel varianten in een gen die door SIFT als deleterieus worden voorspeld.

    Args:
        gene: Gennaam
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
    Geef high-impact varianten waarbij minstens één ALS-patiënt homozygoot is
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
    Geef de meest deleterieuze varianten in een gen (CADD + SIFT + PolyPhen).
    Definitie: CADDphred > 20 EN SIFT = 'D' EN PolyPhen = 'D'.

    Args:
        gene: Gennaam
        top_n: Aantal te tonen varianten (standaard 10)
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
# 4. ANALYTISCHE QUERIES
# ══════════════════════════════════════════════════════════════════════════════

@mcp.tool()
def get_highest_af_variant() -> list[dict]:
    """Geef de variant met de hoogste allelfrequentie."""
    return _query(
        "SELECT VAR_id, MAX(AF) AS highest_allele_frequency "
        "FROM varInfo_synthetic"
    )


@mcp.tool()
def get_average_af_by_impact() -> list[dict]:
    """Gemiddelde allelfrequentie per impactcategorie (Synonymous, ModerateImpact, HighImpact)."""
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
    Hoeveel high-impact varianten draagt een opgegeven sample?
    Geeft het aantal heterozygote (genotype=1) en homozygote (genotype=2) varianten.

    Args:
        sample_id: Sample-naam, bijv. 'ALS_1' of 'Control_3'
    """
    allowed = [f"ALS_{i}" for i in range(1, 6)] + [f"Control_{i}" for i in range(1, 6)]
    if sample_id not in allowed:
        raise ValueError(f"Onbekende sample '{sample_id}'. Kies uit: {', '.join(allowed)}")
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
    Totale allelbelasting (effect allelen) voor cases vs. controls.
    Elke drager levert genotype-waarde (0/1/2) bij aan de totale som.
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
    Top varianten met de hoogste case/control ratio (allel-count).

    Args:
        top_n: Aantal te tonen varianten (standaard 10)
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
    Samenvatting per gen: variant-aantallen, impact-verdeling, gemiddelde AF
    en genomische positie. Alleen genen met meer dan min_variants varianten.

    Args:
        min_variants: Minimaal aantal varianten (standaard 10)
        order_by: Kolomnaam om op te sorteren: total_variants, high_impact_count,
                  moderate_impact_count, mean_AF, of length (standaard total_variants)
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
# 5. CARRIER ANALYSE
# ══════════════════════════════════════════════════════════════════════════════

@mcp.tool()
def get_carriers_by_gene(gene: str, group: str = "ALS") -> list[dict]:
    """
    Geef varianten in een gen waarbij minstens één persoon uit de groep drager is.

    Args:
        gene: Gennaam
        group: 'ALS' of 'Control'
    """
    group_upper = group.strip().upper()
    if group_upper == "ALS":
        cols = [f"ALS_{i}" for i in range(1, 6)]
    elif group_upper == "CONTROL":
        cols = [f"Control_{i}" for i in range(1, 6)]
    else:
        raise ValueError("group moet 'ALS' of 'Control' zijn.")
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
    Geef varianten per gen op impact-niveau gefilterd.

    Args:
        gene: Gennaam
        impact: 'HIGH', 'MODERATE', of 'SYNONYMOUS'
        limit: Maximaal aantal rijen (standaard 200)
    """
    impact_map = {"HIGH": "HighImpact", "MODERATE": "ModerateImpact", "SYNONYMOUS": "Synonymous"}
    col = impact_map.get(impact.strip().upper())
    if not col:
        raise ValueError("impact moet 'HIGH', 'MODERATE' of 'SYNONYMOUS' zijn.")
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
# 6. DATABASE SAMENVATTING
# ══════════════════════════════════════════════════════════════════════════════

@mcp.tool()
def summarize_database() -> dict:
    """Globale statistieken van de varInfo_synthetic tabel."""
    con = get_con()
    try:
        def s(sql):
            return con.execute(sql).fetchone()[0]
        return {
            "totaal_varianten":     s("SELECT COUNT(*)                   FROM varInfo_synthetic"),
            "unieke_genen":         s("SELECT COUNT(DISTINCT gene_name)  FROM varInfo_synthetic"),
            "high_impact":          s("SELECT COUNT(*) FROM varInfo_synthetic WHERE HighImpact = 1"),
            "moderate_impact":      s("SELECT COUNT(*) FROM varInfo_synthetic WHERE ModerateImpact = 1"),
            "synonymous":           s("SELECT COUNT(*) FROM varInfo_synthetic WHERE Synonymous = 1"),
            "sift_deleterious":     s("SELECT COUNT(*) FROM varInfo_synthetic WHERE SIFT = 'D'"),
            "polyphen_damaging":    s("SELECT COUNT(*) FROM varInfo_synthetic WHERE PolyPhen = 'D'"),
            "gemiddelde_allelfreq": s("SELECT ROUND(AVG(AF), 6) FROM varInfo_synthetic"),
            "database_pad":         DB_PATH,
            "genome_build":         "GRCh38",
            "niet_beschikbaar":     (
                "Leeftijd, geslacht van dragers, populatie-specifieke AF, "
                "pathogeniciteitsstatus (ClinVar), eerdere publicaties."
            ),
        }
    finally:
        con.close()


# ══════════════════════════════════════════════════════════════════════════════
# 7. DATA-BEPERKINGEN TOOL
# ══════════════════════════════════════════════════════════════════════════════

@mcp.tool()
def get_database_limitations() -> dict:
    """
    Beschrijft expliciet wat NIET beschikbaar is in de database.
    Roep dit aan vóór je een vraag beantwoordt die mogelijk buiten de data valt.
    """
    return {
        "ontbrekende_velden": {
            "leeftijd": {
                "beschikbaar": False,
                "uitleg": (
                    "Er is geen leeftijdsinformatie beschikbaar voor cases of controls. "
                    "Vragen als 'wat is de gemiddelde leeftijd van ALS-patiënten' "
                    "kunnen NIET worden beantwoord."
                ),
            },
            "geslacht_dragers": {
                "beschikbaar": False,
                "uitleg": (
                    "varInfo_synthetic heeft geen sex-kolom. De tabel SM heeft wel "
                    "een sex-kolom (IID, sex), maar deze is niet gekoppeld aan de "
                    "genotype-kolommen ALS_1..ALS_5 / Control_1..Control_5. "
                    "Vragen als 'hoeveel vrouwelijke dragers zijn er' kunnen NIET "
                    "worden beantwoord via SQLite alleen."
                ),
            },
            "populatie_specifieke_AF": {
                "beschikbaar": False,
                "uitleg": (
                    "De AF-kolom is een globale allelfrequentie. Er zijn geen "
                    "populatie-specifieke frequenties (EUR, SAS, AFR enz.). "
                    "Vragen als 'wat is de AF in Europeanen' kunnen NIET worden beantwoord."
                ),
            },
            "pathogeniciteit": {
                "beschikbaar": False,
                "uitleg": (
                    "Er is geen pathogeniciteitsinformatie (bijv. ClinVar-classificatie). "
                    "Vragen als 'is variant X pathogeen' kunnen NIET worden beantwoord."
                ),
            },
            "eerdere_rapportages": {
                "beschikbaar": False,
                "uitleg": (
                    "Er is geen informatie over eerder gepubliceerde varianten. "
                    "Vragen als 'is VAR_id 100 eerder gerapporteerd' kunnen NIET worden beantwoord."
                ),
            },
        },
        "onmogelijke_combinaties": {
            "synonymous_en_high_impact": {
                "mogelijk": False,
                "uitleg": (
                    "Een variant kan biologisch gezien NIET tegelijk synonymous "
                    "(geen aminozuurverandering) EN high-impact zijn."
                ),
            },
        },
        "vaag_of_subjectief": {
            "belangrijkste_varianten": {
                "actie": "Vraag om verduidelijking",
                "uitleg": (
                    "'Belangrijkste' is subjectief. Verduidelijk: bedoelt de gebruiker "
                    "hoogste CADD-score, high-impact, sterkste case-enrichment, of iets anders?"
                ),
            },
            "meest_deleterieus": {
                "actie": "Definieer en vermeld de definitie",
                "uitleg": (
                    "'Meest deleterieus' is ambigu. Gebruik bij voorkeur een combinatie "
                    "van CADDphred, SIFT='D' en PolyPhen='D', en vermeld altijd welke definitie je hebt gebruikt."
                ),
            },
        },
        "geavanceerd_rvat": {
            "beschikbaar_via_sql": False,
            "uitleg": (
                "Populatie-gestratificeerde analyses, MAF-berekeningen per cohort en "
                "burden-tests vereisen het R-pakket `rvat` en kunnen niet puur via SQLite worden gedaan."
            ),
        },
    }


# ══════════════════════════════════════════════════════════════════════════════
# ENTRYPOINT
# ══════════════════════════════════════════════════════════════════════════════

if __name__ == "__main__":
    mcp.run(transport="stdio")
