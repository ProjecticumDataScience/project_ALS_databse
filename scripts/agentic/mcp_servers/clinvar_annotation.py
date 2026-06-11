#!/usr/bin/env python3
# ══════════════════════════════════════════════════════════════════════════════
# clinvar_annotation.py — ClinVar annotation tools
#
# Uses rsIDs from varInfo_synthetic.ID column to look up ClinVar data.
# Two modes:
#   1. Local SQLite cache (clinvar_cache.db) — fast, fully offline
#   2. NCBI E-utilities fallback — requires internet, used to build cache
#
# Build the local cache by running:
#   python3 clinvar_annotation.py --build-cache
# ══════════════════════════════════════════════════════════════════════════════
import os
import sqlite3
import pathlib
import json
import time
import argparse
from mcp.server.fastmcp import FastMCP

_script_dir = pathlib.Path(__file__).parent.resolve()
DB_PATH     = os.path.expanduser(
    os.environ.get("RVAT_GDB_PATH", str(_script_dir.parent / "rvatData.gdb"))
)
CACHE_PATH  = str(_script_dir / "clinvar_cache.db")

mcp = FastMCP("clinvar_annotation")


## ── SQLite helpers ───────────────────────────────────────────────────────────

def get_rvat_con():
    uri = f"file:{DB_PATH}?mode=ro"
    con = sqlite3.connect(uri, uri=True)
    con.row_factory = sqlite3.Row
    return con


def get_cache_con():
    con = sqlite3.connect(CACHE_PATH)
    con.row_factory = sqlite3.Row
    con.execute("""
        CREATE TABLE IF NOT EXISTS clinvar (
            rsid            TEXT PRIMARY KEY,
            var_id          INTEGER,
            gene_name       TEXT,
            clinical_sig    TEXT,
            review_status   TEXT,
            condition       TEXT,
            variation_id    TEXT,
            last_updated    TEXT
        )
    """)
    con.commit()
    return con


## ── NCBI lookup ──────────────────────────────────────────────────────────────

def fetch_clinvar_for_rsid(rsid: str) -> dict | None:
    """Fetch ClinVar data for a single rsID from NCBI E-utilities."""
    try:
        import urllib.request
        import urllib.parse

        ## Step 1: esearch to get ClinVar variation IDs for this rsID
        rsid_clean = rsid.lstrip("rs")
        search_url = (
            f"https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi"
            f"?db=clinvar&term={rsid_clean}[rsid]&retmode=json"
        )
        with urllib.request.urlopen(search_url, timeout=10) as r:
            data = json.loads(r.read())

        ids = data.get("esearchresult", {}).get("idlist", [])
        if not ids:
            return None

        ## Step 2: esummary to get clinical significance
        summary_url = (
            f"https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi"
            f"?db=clinvar&id={ids[0]}&retmode=json"
        )
        with urllib.request.urlopen(summary_url, timeout=10) as r:
            summ = json.loads(r.read())

        result = summ.get("result", {}).get(ids[0], {})
        if not result:
            return None

        ## Handle both old and new NCBI API response formats
        clin_sig = result.get("clinical_significance", {})
        ## New format uses germline_classification
        germline = result.get("germline_classification", {})

        description = (
            clin_sig.get("description") or
            germline.get("description") or
            result.get("accession", {}).get("clinical_significance") or
            "unknown"
        )
        review = (
            clin_sig.get("review_status") or
            germline.get("review_status") or
            "unknown"
        )
        ## Condition from trait_set or condition_list
        conditions = []
        for t in result.get("trait_set", []):
            name = t.get("preferred_name") or t.get("trait_name", "")
            if name: conditions.append(name)
        if not conditions:
            for t in result.get("condition_list", []):
                name = t.get("name", "")
                if name: conditions.append(name)

        return {
            "variation_id":  ids[0],
            "clinical_sig":  description,
            "review_status": review,
            "condition":     "; ".join(conditions)[:300],
            "last_updated":  result.get("last_evaluated", ""),
        }
    except Exception:
        return None


## ── MCP tools ────────────────────────────────────────────────────────────────

@mcp.tool()
def get_clinvar_for_variant(var_id: int) -> list[dict]:
    """
    Look up ClinVar clinical significance for a specific variant by VAR_id.
    Uses the rsID from varInfo_synthetic.ID to query ClinVar.

    Returns:
      - clinical_sig: e.g. 'Pathogenic', 'Likely pathogenic', 'Benign',
                          'Uncertain significance', 'not provided'
      - review_status: e.g. 'criteria provided, single submitter'
      - condition: disease/phenotype associated in ClinVar
      - source: 'cache' or 'ncbi_live'

    If no ClinVar record exists, returns a message explaining this.

    Args:
        var_id: The VAR_id from varInfo_synthetic
    """
    ## Get rsID from varInfo_synthetic
    rvat = get_rvat_con()
    try:
        row = rvat.execute(
            "SELECT VAR_id, ID, gene_name, CHROM, POS FROM varInfo_synthetic WHERE VAR_id = ?",
            (var_id,)
        ).fetchone()
    finally:
        rvat.close()

    if not row:
        return [{"error": f"VAR_id {var_id} not found in varInfo_synthetic"}]

    rsid      = row["ID"]
    gene_name = row["gene_name"]

    ## If no rsID, can't look up ClinVar
    if not rsid or rsid == "." or not rsid.startswith("rs"):
        return [{
            "var_id":      var_id,
            "gene_name":   gene_name,
            "rsid":        rsid,
            "message":     "No rsID available — ClinVar lookup requires an rsID (rs*). "
                           "This variant has no known rsID in the dataset.",
            "clinical_sig": "not available"
        }]

    ## Check local cache first
    cache = get_cache_con()
    try:
        cached = cache.execute(
            "SELECT * FROM clinvar WHERE rsid = ?", (rsid,)
        ).fetchone()

        if cached:
            return [{
                "var_id":       var_id,
                "gene_name":    gene_name,
                "rsid":         rsid,
                "clinical_sig": cached["clinical_sig"],
                "review_status": cached["review_status"],
                "condition":    cached["condition"],
                "variation_id": cached["variation_id"],
                "source":       "cache"
            }]

        ## Fetch from NCBI
        result = fetch_clinvar_for_rsid(rsid)
        time.sleep(0.4)  ## NCBI rate limit: max 3 req/sec without API key

        if result:
            cache.execute("""
                INSERT OR REPLACE INTO clinvar
                (rsid, var_id, gene_name, clinical_sig, review_status,
                 condition, variation_id, last_updated)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, (rsid, var_id, gene_name,
                  result["clinical_sig"], result["review_status"],
                  result["condition"],    result["variation_id"],
                  result["last_updated"]))
            cache.commit()
            return [{
                "var_id":       var_id,
                "gene_name":    gene_name,
                "rsid":         rsid,
                "clinical_sig": result["clinical_sig"],
                "review_status": result["review_status"],
                "condition":    result["condition"],
                "variation_id": result["variation_id"],
                "source":       "ncbi_live"
            }]
        else:
            return [{
                "var_id":       var_id,
                "gene_name":    gene_name,
                "rsid":         rsid,
                "clinical_sig": "not in ClinVar",
                "message":      f"{rsid} has no ClinVar record.",
                "source":       "ncbi_live"
            }]
    finally:
        cache.close()


@mcp.tool()
def get_clinvar_for_gene(gene: str, sig_filter: str = "all") -> list[dict]:
    """
    Get ClinVar annotations for all variants in a gene that have rsIDs.
    Only returns variants that have ClinVar records.

    Args:
        gene:       Gene name e.g. 'SOD1', 'NEK1', 'TARDBP'
        sig_filter: Filter by significance: 'pathogenic', 'benign',
                    'uncertain', or 'all' (default)
    """
    rvat = get_rvat_con()
    try:
        rows = rvat.execute(
            "SELECT VAR_id, ID, gene_name FROM varInfo_synthetic "
            "WHERE gene_name = ? AND ID IS NOT NULL AND ID LIKE 'rs%'",
            (gene,)
        ).fetchall()
    finally:
        rvat.close()

    if not rows:
        return [{"message": f"No variants with rsIDs found in {gene}"}]

    results = []
    cache = get_cache_con()
    try:
        for row in rows:
            rsid   = row["ID"]
            var_id = row["VAR_id"]

            cached = cache.execute(
                "SELECT * FROM clinvar WHERE rsid = ?", (rsid,)
            ).fetchone()

            if not cached:
                ## Try NCBI
                ncbi = fetch_clinvar_for_rsid(rsid)
                time.sleep(0.4)
                if ncbi:
                    cache.execute("""
                        INSERT OR REPLACE INTO clinvar
                        (rsid, var_id, gene_name, clinical_sig, review_status,
                         condition, variation_id, last_updated)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, (rsid, var_id, gene,
                          ncbi["clinical_sig"], ncbi["review_status"],
                          ncbi["condition"],    ncbi["variation_id"],
                          ncbi["last_updated"]))
                    cache.commit()
                    cached_sig = ncbi["clinical_sig"]
                    cached_cond = ncbi["condition"]
                    variation_id = ncbi["variation_id"]
                else:
                    continue  ## no ClinVar record, skip
            else:
                cached_sig   = cached["clinical_sig"]
                cached_cond  = cached["condition"]
                variation_id = cached["variation_id"]

            ## Apply significance filter
            sig_lower = cached_sig.lower()
            if sig_filter == "pathogenic" and "pathogenic" not in sig_lower:
                continue
            if sig_filter == "benign" and "benign" not in sig_lower:
                continue
            if sig_filter == "uncertain" and "uncertain" not in sig_lower:
                continue

            results.append({
                "var_id":       var_id,
                "rsid":         rsid,
                "gene_name":    gene,
                "clinical_sig": cached_sig,
                "condition":    cached_cond,
                "variation_id": variation_id,
            })
    finally:
        cache.close()

    if not results:
        return [{"message": f"No ClinVar records found for {gene} (filter: {sig_filter})"}]
    return results


@mcp.tool()
def get_clinvar_summary_by_gene() -> list[dict]:
    """
    Summary of ClinVar coverage across all genes in varInfo_synthetic.
    Shows how many variants per gene have rsIDs and ClinVar records.
    Useful for understanding what ClinVar data is available.
    """
    rvat = get_rvat_con()
    try:
        rows = rvat.execute("""
            SELECT gene_name,
                   COUNT(*) AS total_variants,
                   SUM(CASE WHEN ID IS NOT NULL AND ID LIKE 'rs%' THEN 1 ELSE 0 END) AS has_rsid
            FROM varInfo_synthetic
            GROUP BY gene_name ORDER BY has_rsid DESC
        """).fetchall()
    finally:
        rvat.close()

    cache = get_cache_con()
    results = []
    try:
        for row in rows:
            n_cached = cache.execute(
                "SELECT COUNT(*) FROM clinvar WHERE gene_name = ?",
                (row["gene_name"],)
            ).fetchone()[0]
            results.append({
                "gene_name":        row["gene_name"],
                "total_variants":   row["total_variants"],
                "has_rsid":         row["has_rsid"],
                "clinvar_cached":   n_cached,
            })
    finally:
        cache.close()
    return results


## ── Cache builder (run standalone) ──────────────────────────────────────────

def build_cache():
    """Pre-fetch ClinVar data for all rsIDs in the database."""
    rvat = get_rvat_con()
    rows = rvat.execute(
        "SELECT VAR_id, ID, gene_name FROM varInfo_synthetic "
        "WHERE ID IS NOT NULL AND ID LIKE 'rs%'"
    ).fetchall()
    rvat.close()

    print(f"Building ClinVar cache for {len(rows)} rsIDs...")
    cache = get_cache_con()
    hits = 0
    for i, row in enumerate(rows):
        rsid   = row["ID"]
        var_id = row["VAR_id"]
        gene   = row["gene_name"]

        ## Skip if already cached
        exists = cache.execute(
            "SELECT 1 FROM clinvar WHERE rsid = ?", (rsid,)
        ).fetchone()
        if exists:
            continue

        result = fetch_clinvar_for_rsid(rsid)
        time.sleep(0.4)

        if result:
            cache.execute("""
                INSERT OR REPLACE INTO clinvar
                (rsid, var_id, gene_name, clinical_sig, review_status,
                 condition, variation_id, last_updated)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, (rsid, var_id, gene,
                  result["clinical_sig"], result["review_status"],
                  result["condition"],    result["variation_id"],
                  result["last_updated"]))
            cache.commit()
            hits += 1

        if (i + 1) % 50 == 0:
            print(f"  {i+1}/{len(rows)} processed, {hits} ClinVar hits so far...")

    cache.close()
    print(f"Done. {hits}/{len(rows)} variants have ClinVar records.")
    print(f"Cache saved to: {CACHE_PATH}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--build-cache", action="store_true",
                        help="Pre-fetch ClinVar data for all rsIDs")
    args = parser.parse_args()

    if args.build_cache:
        build_cache()
    else:
        mcp.run(transport="stdio")
