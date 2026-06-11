#!/usr/bin/env python3
# ══════════════════════════════════════════════════════════════════════════════
# rvat_bridge.py — FastMCP bridge to the plumber rvat HTTP server
#
# This thin Python wrapper exposes the plumber endpoints as MCP tools
# so mcpo can proxy them to the LLM alongside the other Python servers.
#
# The plumber server (rvat_server.R) must be running on RVAT_PORT (default 8009)
# before this bridge starts.
# ══════════════════════════════════════════════════════════════════════════════
import os
import json
import urllib.request
import urllib.error
from mcp.server.fastmcp import FastMCP

RVAT_PORT = int(os.environ.get("RVAT_PORT", "8009"))
RVAT_BASE = f"http://localhost:{RVAT_PORT}"

mcp = FastMCP("rvat_analysis")


def _call_plumber(endpoint: str, params: dict) -> list[dict]:
    """POST to a plumber endpoint and return parsed JSON."""
    url  = f"{RVAT_BASE}/{endpoint.lstrip('/')}"
    body = json.dumps(params).encode()
    req  = urllib.request.Request(
        url, data=body,
        headers={"Content-Type": "application/json"},
        method="POST"
    )
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            raw = r.read().decode()
            parsed = json.loads(raw)
            ## plumber wraps single objects in a list
            if isinstance(parsed, dict):
                return [parsed]
            return parsed
    except urllib.error.HTTPError as e:
        return [{"error": f"HTTP {e.code}: {e.reason}"}]
    except Exception as e:
        return [{"error": str(e)}]


@mcp.tool()
def run_burden_test(
    gene: str,
    test: str = "firth",
    impact_filter: str = "high_moderate",
    max_af: float | None = None,
    covar: str = "sex"
) -> list[dict]:
    """
    Run a statistical burden test (aggregate rare variant test) for a gene.

    Compares rare variant burden between ALS cases and controls using
    the rvat framework. Returns p-value, carrier counts, and effect estimates.

    Args:
        gene:          Gene name e.g. 'NEK1', 'SOD1', 'FUS'. Required.
        test:          Statistical test. Options:
                         'firth'       — Firth logistic regression (best for small n, default)
                         'skat'        — SKAT test
                         'skat_burden' — SKAT burden test
                         'skato'       — SKAT-O unified test
                         'glm'         — standard logistic regression
                         'acatv'       — ACAT-V test
        impact_filter: Which variants to include:
                         'high_moderate' — high + moderate impact (default, recommended)
                         'high'          — high impact only
                         'moderate'      — moderate impact only
                         'any'           — all variants
                         'synonymous'    — synonymous only (negative control)
        max_af:        Maximum allele frequency cutoff e.g. 0.01 for 1%.
                       None means no AF filter (default).
        covar:         Covariates as comma-separated string e.g. 'sex,PC1,PC2'.
                       Default: 'sex'. Must exist as columns in the pheno table.

    Returns:
        List with fields: unit (gene), P (p-value), caseCarriers, ctrlCarriers,
        nvar, test, effect, OR, caseN, ctrlN, and more.
        A low P-value (< 0.05) indicates significant case enrichment.
    """
    params = {"gene": gene, "test": test, "impact_filter": impact_filter,
              "covar": covar}
    if max_af is not None:
        params["max_af"] = max_af
    return _call_plumber("run_burden_test", params)


@mcp.tool()
def run_burden_all_genes(
    test: str = "firth",
    impact_filter: str = "high_moderate",
    max_af: float | None = None,
    covar: str = "sex"
) -> list[dict]:
    """
    Run burden tests across ALL 12 genes and return results ranked by p-value.

    Identifies which genes show significant rare variant burden differences
    between ALS cases and controls. Results are sorted by p-value ascending.

    Args:
        test:          Statistical test (same options as run_burden_test).
                       Default: 'firth'.
        impact_filter: Variant filter (same options as run_burden_test).
                       Default: 'high_moderate'.
        max_af:        Maximum allele frequency cutoff. None = no filter.
        covar:         Covariates. Default: 'sex'.

    Returns:
        List of results per gene, sorted by P-value ascending.
        Fields include: unit (gene), P, caseCarriers, ctrlCarriers, nvar, OR.
        Note: with only 5 cases and 5 controls, p-values should be interpreted
        with caution — this is a synthetic dataset.
    """
    params = {"test": test, "impact_filter": impact_filter, "covar": covar}
    if max_af is not None:
        params["max_af"] = max_af
    return _call_plumber("run_burden_all_genes", params)


@mcp.tool()
def get_variant_summary(
    gene: str,
    impact_filter: str = "any"
) -> list[dict]:
    """
    Get per-variant genotype summary statistics for a gene.

    Returns allele frequencies, carrier counts, call rates, and genotype
    count distributions (HOM_REF, HET, HOM_ALT) computed directly from
    the genotype matrix via rvat.

    Args:
        gene:          Gene name e.g. 'NEK1', 'SOD1'. Required.
        impact_filter: Variant filter: 'any' (default), 'high', 'moderate',
                       'high_moderate', 'synonymous'.

    Returns:
        Per-variant summary with fields: VAR_id, AF, MAC, nCarriers,
        callRate, nHOM_REF, nHET, nHOM_ALT, HWE_P.
    """
    return _call_plumber("get_variant_summary", {
        "gene": gene, "impact_filter": impact_filter
    })


@mcp.tool()
def get_carrier_info(
    gene: str,
    impact_filter: str = "high",
    var_id: int | None = None
) -> list[dict]:
    """
    Get sample-level carrier information for variants in a gene.

    Returns which samples carry each variant, with their phenotype (ALS/control),
    sex, and population. Computed from the rvat genotype matrix joined with
    the pheno cohort table.

    Args:
        gene:          Gene name e.g. 'SOD1'. Required.
        impact_filter: Variant filter: 'high' (default), 'moderate', 'any'.
        var_id:        Optional specific VAR_id to look up. None = all variants.

    Returns:
        Per-carrier rows with: IID, VAR_id, gene_name, pheno (1=ALS, 0=control),
        sex (1=female, 2=male), superPop, pop, CADDphred, HighImpact.
    """
    params = {"gene": gene, "impact_filter": impact_filter}
    if var_id is not None:
        params["var_id"] = var_id
    return _call_plumber("get_carrier_info", params)




@mcp.tool()
def run_single_variant_test(
    gene: str,
    test: str = "scoreSPA",
    impact_filter: str = "any",
    max_af: float | None = None,
    covar: str = "sex"
) -> list[dict]:
    """
    Run per-variant association tests for all variants in a gene.

    Returns a p-value, effect estimate, and allele counts for each individual
    variant. Results sorted by p-value. Useful for identifying which specific
    variants drive the association signal in a gene.

    Args:
        gene:          Gene name e.g. 'SOD1', 'NEK1'. Required.
        test:          Single variant test:
                         'scoreSPA' — score test with saddlepoint approximation (default)
                         'firth'    — Firth logistic regression
                         'glm'      — standard logistic regression
        impact_filter: Variant filter: 'any' (default), 'high', 'moderate', 'high_moderate'.
        max_af:        Maximum allele frequency cutoff. None = no filter.
        covar:         Covariates. Default: 'sex'.

    Returns:
        Per-variant results sorted by P-value with: VAR_id, P, effect, OR,
        caseMAC, ctrlMAC, effectAllele, otherAllele.
    """
    params = {"gene": gene, "test": test, "impact_filter": impact_filter, "covar": covar}
    if max_af is not None:
        params["max_af"] = max_af
    return _call_plumber("run_single_variant_test", params)


@mcp.tool()
def get_maf_by_impact(
    gene: str,
    impact_filter: str = "any"
) -> list[dict]:
    """
    Get minor allele frequencies (MAF) for variants in a gene, grouped by impact.

    Computes MAF directly from the genotype matrix via rvat — more accurate than
    the AF column in varInfo as it accounts for ploidy and sex chromosomes.
    Returns per-variant MAF plus a SUMMARY row with mean MAF for the gene.

    Args:
        gene:          Gene name e.g. 'TARDBP', 'NEK1'. Required.
        impact_filter: 'any' (default), 'high', 'moderate', 'high_moderate', 'synonymous'.

    Returns:
        First row is SUMMARY (mean MAF across all variants).
        Subsequent rows are per-variant: VAR_id, MAF, AF, MAC, nCarriers,
        HighImpact, ModImpact, Synonymous, CADDphred.
    """
    return _call_plumber("get_maf_by_impact", {"gene": gene, "impact_filter": impact_filter})


@mcp.tool()
def get_ld_matrix(
    gene: str,
    impact_filter: str = "high",
    min_r2: float = 0.1
) -> list[dict]:
    """
    Compute linkage disequilibrium (LD/correlation) between variants in a gene.

    Uses rvat buildCorMatrix to compute pairwise r-squared (LD) values between
    variants. Returns variant pairs with r2 above the threshold, sorted by r2.
    This makes LD questions answerable — the database DOES contain genotype data
    from which LD can be computed.

    Args:
        gene:          Gene name e.g. 'NEK1', 'SOD1'. Required.
        impact_filter: 'high' (default — fewer variants, faster), 'any', 'moderate'.
        min_r2:        Minimum r-squared to report. Default 0.1.
                       Set lower (e.g. 0.01) to see more pairs.

    Returns:
        Pairs of variants with r2 >= min_r2: VAR_id_1, VAR_id_2, r2.
        Sorted by r2 descending. High r2 (>0.8) means strong LD.
    """
    return _call_plumber("get_ld_matrix", {
        "gene": gene, "impact_filter": impact_filter, "min_r2": min_r2
    })


@mcp.tool()
def get_cohort_summary() -> list[dict]:
    """
    Get cohort/sample summary from the rvat database.

    Returns total sample counts, phenotype distribution (cases vs controls),
    sex distribution, and population breakdown from the rvat pheno table.

    Returns:
        n_total, n_cases, n_controls, n_female, n_male, pop_counts,
        columns_available (list of all pheno table columns).
    """
    return _call_plumber("get_cohort_summary", {})


if __name__ == "__main__":
    mcp.run(transport="stdio")
