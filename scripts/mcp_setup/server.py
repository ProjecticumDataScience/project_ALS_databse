import sqlite3
from mcp.server.fastmcp import FastMCP

# Directory to databse
DB_PATH = "/Library/Frameworks/R.framework/Versions/4.5-arm64/Resources/library/rvatData/extdata/rvatData.gdb"

mcp = FastMCP("rvatData")

def get_con():
    con = sqlite3.connect(DB_PATH)
    con.row_factory = sqlite3.Row
    return con


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
    Describe the columns of a table: name, type, and whether it can be null.
    Use this to understand what data a table contains before querying it.
    """
    con = get_con()
    rows = con.execute(f"PRAGMA table_info({table_name})").fetchall()
    con.close()
    return [{"name": r["name"], "type": r["type"], "notnull": r["notnull"]} for r in rows]


@mcp.tool()
def run_query(sql: str) -> list[dict]:
    """
    Run a read-only SELECT query against the rvatData SQLite database and return results.
    Maximum 200 rows are returned. Only SELECT statements are allowed.
    Always use this tool to answer any question about the database — never guess or make up answers.
    If a question cannot be answered with the available data, say so clearly.

    DATABASE SCHEMA:
    - varInfo_synthetic: the main table for variant analysis. Contains:
        VAR_id, CHROM, POS, ID, REF, ALT, QUAL, FILTER, AC, AN, AF (allele frequency),
        gene_name, HighImpact (0/1), ModerateImpact (0/1), Synonymous (0/1),
        CADDphred (deleteriousness score, higher = more deleterious),
        PolyPhen (protein impact prediction: 'D'=damaging, 'P'=possibly damaging, 'B'=benign),
        SIFT (protein impact prediction: 'D'=deleterious, 'T'=tolerated),
        ALS_1, ALS_2, ALS_3, ALS_4, ALS_5 (genotypes for 5 ALS cases),
        Control_1, Control_2, Control_3, Control_4, Control_5 (genotypes for 5 controls).
        Genotype values: 0 = homozygous reference, 1 = heterozygous, 2 = homozygous alternative.

    - varInfo: same structure as varInfo_synthetic but without the genotype columns.

    - var: raw variant table (VAR_id, CHROM, POS, ID, REF, ALT, QUAL, FILTER, INFO, FORMAT).

    - pheno: sample phenotype table (IID, sex, pheno, pop, superPop, PC1-PC4, age).
        pheno column: 1 = ALS case, 0 = control. sex: 1 = male, 2 = female.
        pop/superPop: population ancestry (e.g. EUR, SAS, AFR).
        Note: pheno does NOT contain genotype data; it only has sample-level info.

    - SM: sample metadata (IID, sex). Basic sample list.

    - meta: database metadata (rvatVersion, genomeBuild). Genome build is GRCh38.

    - cohort: cohort-level metadata.

    - var_ranges: genomic range index for variants.

    - anno: additional annotations.

    - dosage: genotype dosage data.

    IMPORTANT NOTES:
    - Age of samples is NOT available in varInfo_synthetic — it is only in pheno.
    - Population-specific allele frequencies are NOT available.
    - Pathogenicity classifications are NOT available.
    - A variant CANNOT be both Synonymous AND HighImpact simultaneously.
    - When "deleterious" or "most damaging" is asked, use a combination of CADDphred, SIFT='D', and PolyPhen='D'.
    - When asked about carriers, use the genotype columns (ALS_1-5, Control_1-5): value > 0 means carrier.
    - When asked about homozygous carriers, use value = 2.
    - Burden = total number of effect alleles = SUM of all genotype columns.
    """
    if not sql.strip().upper().startswith("SELECT"):
        raise ValueError("Only SELECT queries are allowed.")
    con = get_con()
    rows = con.execute(sql).fetchmany(200)
    con.close()
    return [dict(r) for r in rows]


@mcp.tool()
def get_sample_rows(table_name: str, n: int = 5) -> list[dict]:
    """
    Return a small sample of rows from a table.
    Useful for exploring what data looks like before writing a query.
    """
    con = get_con()
    rows = con.execute(f"SELECT * FROM {table_name} LIMIT {n}").fetchall()
    con.close()
    return [dict(r) for r in rows]


if __name__ == "__main__":
    mcp.run()
