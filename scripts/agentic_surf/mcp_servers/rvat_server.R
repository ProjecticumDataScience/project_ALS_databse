# ══════════════════════════════════════════════════════════════════════════════
# rvat_server.R — plumber REST API wrapping rvat statistical functions
#
# Exposes rvat burden testing, variant set building, and genotype retrieval
# as HTTP endpoints that mcpo can proxy to the LLM as MCP tools.
#
# Start with:
#   Rscript -e "plumber::plumb('rvat_server.R')$run(port=8009, host='0.0.0.0')"
#
# Or via start_services.sh (recommended)
# ══════════════════════════════════════════════════════════════════════════════

library(plumber)
library(rvat)
library(jsonlite)

## ── Load database once at startup ────────────────────────────────────────────
GDB_PATH <- path.expand(
  Sys.getenv("RVAT_GDB_PATH",
             "~/project_ALS_databse/references/rvatData.gdb")
)

cat("[rvat_server] Loading gdb from:", GDB_PATH, "\n")
db <- gdb(GDB_PATH)
cat("[rvat_server] gdb loaded successfully\n")

## ── Helper: build varSetFile and return path ─────────────────────────────────
make_varset <- function(gene, impact_filter = "any", max_af = NULL) {
  vsf_path <- tempfile(fileext = ".rvat")
  
  ## Build WHERE clause
  where_parts <- character(0)
  
  if (!is.null(gene) && gene != "" && gene != "all") {
    where_parts <- c(where_parts, sprintf("gene_name = '%s'", gene))
  }
  
  if (impact_filter == "high") {
    where_parts <- c(where_parts, "HighImpact = '1'")
  } else if (impact_filter == "moderate") {
    where_parts <- c(where_parts, "ModerateImpact = '1'")
  } else if (impact_filter == "synonymous") {
    where_parts <- c(where_parts, "Synonymous = '1'")
  } else if (impact_filter == "high_moderate") {
    where_parts <- c(where_parts, "(HighImpact = '1' OR ModerateImpact = '1')")
  }
  
  if (!is.null(max_af) && is.numeric(max_af)) {
    where_parts <- c(where_parts,
                     sprintf("CAST(AF AS REAL) <= %f", max_af),
                     "AF != '.'")
  }
  
  where_clause <- if (length(where_parts) > 0) {
    paste(where_parts, collapse = " AND ")
  } else {
    "1=1"
  }
  
  buildVarSet(
    object      = db,
    output      = vsf_path,
    varSetName  = impact_filter,
    unitTable   = "varInfo",
    unitName    = "gene_name",
    where       = where_clause
  )
  
  vsf_path
}

## ── Helper: safe JSON conversion ─────────────────────────────────────────────
to_json_safe <- function(x) {
  df <- tryCatch(as.data.frame(x), error = function(e) data.frame(error = e$message))
  ## Replace Inf/-Inf/NaN with NA for clean JSON
  df[] <- lapply(df, function(col) {
    if (is.numeric(col)) replace(col, !is.finite(col), NA)
    else col
  })
  df
}

## Convert a data frame to row-oriented list for clean JSON
df_to_rows <- function(df) {
  lapply(seq_len(nrow(df)), function(i) as.list(df[i, , drop = FALSE]))
}


#* @apiTitle rvat Analysis Server
#* @apiDescription Statistical burden testing and genotype analysis via rvat


## ════════════════════════════════════════════════════════════════════════════
## ENDPOINT 1: run_burden_test
## ════════════════════════════════════════════════════════════════════════════

#* Run a statistical burden test for a gene
#*
#* Performs a rare variant burden test (aggregate test) comparing ALS cases
#* vs controls for variants in a specified gene. Returns p-value, carrier
#* counts, and effect estimates where available.
#*
#* @param gene Gene name to test (e.g. NEK1, SOD1, FUS). Required.
#* @param test Statistical test: firth (default), skat, skat_burden, skato,
#*             glm, acatv. Use firth for small samples.
#* @param impact_filter Which variants to include: any (default), high,
#*                      moderate, high_moderate, synonymous.
#* @param max_af Maximum allele frequency filter (e.g. 0.01 for 1% AF).
#*               NULL means no filter.
#* @param covar Covariates to include as comma-separated string.
#*              Default: "sex" (sex is available in the pheno table).
#* @post /run_burden_test
function(gene, test = "firth", impact_filter = "any",
         max_af = NULL, covar = "sex", res = NULL) {
  tryCatch({
    if (is.null(gene) || gene == "")
      return(list(error = "gene parameter is required"))
    
    max_af_num <- if (!is.null(max_af) && max_af != "") as.numeric(max_af) else NULL
    covar_vec  <- if (!is.null(covar) && covar != "") {
      trimws(strsplit(covar, ",")[[1]])
    } else NULL
    
    ## Build variant set
    vsf_path <- make_varset(gene, impact_filter, max_af_num)
    vsf      <- varSetFile(vsf_path)
    vs       <- tryCatch(getVarSet(vsf, unit = gene),
                         error = function(e) NULL)
    
    if (is.null(vs) || length(vs) == 0)
      return(list(
        gene   = gene,
        error  = paste0("No variants found for gene '", gene,
                        "' with filter: ", impact_filter)
      ))
    
    ## Load genotype matrix
    GT <- getGT(db, varSet = vs, cohort = "pheno")
    
    if (ncol(GT) == 0 || nrow(GT) == 0)
      return(list(gene = gene, error = "Empty genotype matrix"))
    
    ## Run burden test
    result <- assocTest(
      GT,
      pheno = "pheno",
      covar = covar_vec,
      test  = test
    )
    
    df <- to_json_safe(result)
    df_to_rows(df)
    
  }, error = function(e) {
    list(gene = gene, error = e$message)
  })
}


## ════════════════════════════════════════════════════════════════════════════
## ENDPOINT 2: run_burden_all_genes
## ════════════════════════════════════════════════════════════════════════════

#* Run burden test across all genes and return ranked results
#*
#* Loops through all 12 genes in the database and runs a burden test for each.
#* Returns results ranked by p-value. Useful for identifying genes with
#* significant case enrichment.
#*
#* @param test Statistical test to use: firth (default), skat, glm.
#* @param impact_filter Variant filter: any, high, moderate, high_moderate.
#* @param max_af Maximum allele frequency (e.g. 0.01). NULL = no filter.
#* @param covar Covariates (comma-separated). Default: "sex".
#* @post /run_burden_all_genes
function(test = "firth", impact_filter = "high_moderate",
         max_af = NULL, covar = "sex", res = NULL) {
  tryCatch({
    max_af_num <- if (!is.null(max_af) && max_af != "") as.numeric(max_af) else NULL
    covar_vec  <- if (!is.null(covar) && covar != "") {
      trimws(strsplit(covar, ",")[[1]])
    } else NULL
    
    ## Build varset across all genes
    vsf_path <- make_varset(gene = NULL, impact_filter, max_af_num)
    vsf      <- varSetFile(vsf_path)
    
    ## Get all available units (genes)
    all_units <- tryCatch({
      vs_all <- getVarSet(vsf)
      unique(sapply(vs_all, function(v) v@unit))
    }, error = function(e) {
      ## Fallback: known genes
      c("ABCA4","RIN3","NEK1","IL3RA","PEX5","OPTN",
        "ZNF483","FUS","CYP19A1","SOD1","UBQLN2","TARDBP")
    })
    
    results <- lapply(all_units, function(g) {
      tryCatch({
        vs <- getVarSet(vsf, unit = g)
        if (is.null(vs) || length(vs) == 0) return(NULL)
        GT <- getGT(db, varSet = vs, cohort = "pheno")
        if (ncol(GT) == 0 || nrow(GT) == 0) return(NULL)
        res <- assocTest(GT, pheno = "pheno", covar = covar_vec, test = test)
        to_json_safe(res)  ## returns data frame
      }, error = function(e) NULL)
    })
    
    results_df <- do.call(rbind, Filter(Negate(is.null), results))
    if (is.null(results_df) || nrow(results_df) == 0)
      return(list(error = "No results produced"))
    
    ## Sort by p-value
    results_df <- results_df[order(results_df$P, na.last = TRUE), ]
    df_to_rows(results_df)
    
  }, error = function(e) {
    list(error = e$message)
  })
}


## ════════════════════════════════════════════════════════════════════════════
## ENDPOINT 3: get_variant_summary
## ════════════════════════════════════════════════════════════════════════════

#* Get genotype summary statistics for variants in a gene
#*
#* Returns per-variant summary including allele frequency, carrier counts,
#* call rates, and genotype counts (HOM_REF, HET, HOM_ALT).
#* Useful for understanding variant-level statistics.
#*
#* @param gene Gene name (required).
#* @param impact_filter Variant filter: any, high, moderate, high_moderate.
#* @post /get_variant_summary
function(gene, impact_filter = "any", res = NULL) {
  tryCatch({
    if (is.null(gene) || gene == "")
      return(list(error = "gene parameter is required"))
    
    vsf_path <- make_varset(gene, impact_filter)
    vsf      <- varSetFile(vsf_path)
    vs       <- tryCatch(getVarSet(vsf, unit = gene), error = function(e) NULL)
    
    if (is.null(vs) || length(vs) == 0)
      return(list(gene = gene, error = "No variants found"))
    
    GT      <- getGT(db, varSet = vs, cohort = "pheno")
    summary <- summariseGeno(GT)
    df      <- to_json_safe(summary)
    df_to_rows(df)
    
  }, error = function(e) {
    list(gene = gene, error = e$message)
  })
}


## ════════════════════════════════════════════════════════════════════════════
## ENDPOINT 4: get_carrier_info
## ════════════════════════════════════════════════════════════════════════════

#* Get carrier information for variants in a gene
#*
#* Returns sample-level carrier information: which samples carry each variant,
#* with their phenotype, sex, and population from the pheno table.
#* Useful for understanding who carries specific variants.
#*
#* @param gene Gene name (required).
#* @param impact_filter Variant filter: any, high, moderate.
#* @param var_id Optional specific VAR_id to look up (integer).
#* @post /get_carrier_info
function(gene, impact_filter = "high", var_id = NULL, res = NULL) {
  tryCatch({
    if (is.null(gene) || gene == "")
      return(list(error = "gene parameter is required"))
    
    vsf_path <- make_varset(gene, impact_filter)
    vsf      <- varSetFile(vsf_path)
    vs       <- tryCatch(getVarSet(vsf, unit = gene), error = function(e) NULL)
    
    if (is.null(vs) || length(vs) == 0)
      return(list(gene = gene, error = "No variants found"))
    
    GT <- getGT(db, varSet = vs, cohort = "pheno")
    
    ## Optionally subset to specific VAR_id
    if (!is.null(var_id) && var_id != "") {
      vid <- as.integer(var_id)
      GT  <- GT[rownames(GT) == as.character(vid), ]
    }
    
    carriers <- getCarriers(
      GT,
      colDataFields = c("pheno", "sex", "superPop", "pop"),
      rowDataFields = c("gene_name", "CADDphred", "HighImpact")
    )
    
    df <- to_json_safe(carriers)
    df_to_rows(df)
    
  }, error = function(e) {
    list(gene = gene, error = e$message)
  })
}



## ════════════════════════════════════════════════════════════════════════════
## ENDPOINT 10: get_carrier_count_filtered
## ════════════════════════════════════════════════════════════════════════════

#* Count carriers of variants in a gene, filtered by sex/population/phenotype
#*
#* Builds on get_carrier_info but counts UNIQUE individuals matching specific
#* phenotype filters (sex, population, case/control status) against the FULL
#* rvat cohort (25,000 samples), not a synthetic subset. Use this for
#* questions like "how many female carriers in the SAS population carry a
#* pathogenic mutation in gene X" — note: "carrier" questions about disease
#* risk typically mean ALS CASES specifically, so phenotype defaults to
#* cases only (1) unless the question asks about controls or both.
#*
#* @param gene Gene name (required).
#* @param impact_filter Variant filter: any, high, moderate, high_moderate
#*                      (default: high_moderate — common "pathogenic" proxy).
#* @param sex Optional sex filter: 1 (female), 2 (male). NULL = all.
#* @param population Optional superPop filter, e.g. 'SAS', 'EUR'. NULL = all.
#* @param phenotype Optional case/control filter: 1 (ALS case), 0 (control).
#*                  NULL = both. Most "carrier" questions implicitly mean cases.
#* @post /get_carrier_count_filtered
function(gene, impact_filter = "high_moderate", sex = NULL, population = NULL,
         phenotype = NULL, res = NULL) {
  tryCatch({
    if (is.null(gene) || gene == "")
      return(list(error = "gene parameter is required"))
    
    vsf_path <- make_varset(gene, impact_filter)
    vsf      <- varSetFile(vsf_path)
    vs       <- tryCatch(getVarSet(vsf, unit = gene), error = function(e) NULL)
    
    if (is.null(vs) || length(vs) == 0)
      return(list(gene = gene, error = "No variants found"))
    
    GT <- getGT(db, varSet = vs, cohort = "pheno")
    
    if (ncol(GT) == 0 || nrow(GT) == 0)
      return(list(gene = gene, error = "Empty genotype matrix"))
    
    ## Get full carrier list against the real cohort (not synthetic subset)
    carriers <- getCarriers(
      GT,
      colDataFields = c("pheno", "sex", "superPop", "pop")
    )
    
    df <- as.data.frame(carriers)
    
    if (nrow(df) == 0)
      return(list(
        gene = gene, impact_filter = impact_filter,
        n_carriers = 0,
        message = "No carriers found"
      ))
    
    ## Apply optional filters
    if (!is.null(sex) && sex != "") {
      sex_num <- as.integer(sex)
      if ("sex" %in% colnames(df)) df <- df[df$sex == sex_num, , drop = FALSE]
    }
    if (!is.null(population) && population != "") {
      pop_upper <- toupper(population)
      if ("superPop" %in% colnames(df)) df <- df[toupper(df$superPop) == pop_upper, , drop = FALSE]
    }
    if (!is.null(phenotype) && phenotype != "") {
      pheno_num <- as.integer(phenotype)
      if ("pheno" %in% colnames(df)) df <- df[df$pheno == pheno_num, , drop = FALSE]
    }
    
    ## Count UNIQUE individuals — a person carrying multiple qualifying
    ## variants in the same gene should only be counted once.
    n_variant_carrier_rows <- nrow(df)
    df_unique <- df[!duplicated(df$IID), , drop = FALSE]
    
    list(
      gene           = gene,
      impact_filter  = impact_filter,
      sex_filter     = if (!is.null(sex)) as.integer(sex) else NA,
      population_filter  = if (!is.null(population)) toupper(population) else NA,
      phenotype_filter   = if (!is.null(phenotype)) as.integer(phenotype) else NA,
      n_unique_carriers  = nrow(df_unique),
      n_variant_carrier_rows = n_variant_carrier_rows,
      note = "n_unique_carriers is the count of distinct individuals — use this for 'how many carriers' questions",
      carriers       = df_to_rows(df_unique)
    )
    
  }, error = function(e) {
    list(gene = gene, error = e$message)
  })
}


## ════════════════════════════════════════════════════════════════════════════
## ENDPOINT 5: server_status
## ════════════════════════════════════════════════════════════════════════════

#* Check rvat server status and database info
#*
#* Returns server status, rvat version, and basic database metadata.
#* Use this to verify the server is running correctly.
#*


## ════════════════════════════════════════════════════════════════════════════
## ENDPOINT 6: run_single_variant_test
## ════════════════════════════════════════════════════════════════════════════

#* Run single variant association tests for all variants in a gene
#*
#* Performs per-variant statistical tests comparing ALS cases vs controls.
#* Returns p-value, effect estimate, and allele counts per variant.
#* Useful for identifying specific variants driving association signals.
#*
#* @param gene Gene name (required).
#* @param test Single variant test: scoreSPA (default), firth, glm.
#* @param impact_filter Variant filter: any, high, moderate, high_moderate.
#* @param max_af Maximum allele frequency cutoff. NULL = no filter.
#* @param covar Covariates (comma-separated). Default: "sex".
#* @post /run_single_variant_test
function(gene, test = "scoreSPA", impact_filter = "any",
         max_af = NULL, covar = "sex", res = NULL) {
  tryCatch({
    if (is.null(gene) || gene == "")
      return(list(error = "gene parameter is required"))
    
    max_af_num <- if (!is.null(max_af) && max_af != "") as.numeric(max_af) else NULL
    covar_vec  <- if (!is.null(covar) && covar != "") {
      trimws(strsplit(covar, ",")[[1]])
    } else NULL
    
    vsf_path <- make_varset(gene, impact_filter, max_af_num)
    vsf      <- varSetFile(vsf_path)
    vs       <- tryCatch(getVarSet(vsf, unit = gene), error = function(e) NULL)
    
    if (is.null(vs) || length(vs) == 0)
      return(list(gene = gene, error = "No variants found"))
    
    GT <- getGT(db, varSet = vs, cohort = "pheno")
    
    result <- assocTest(
      GT,
      pheno     = "pheno",
      covar     = covar_vec,
      test      = test,
      singlevar = TRUE
    )
    
    df <- to_json_safe(result)
    ## Sort by p-value
    if ("P" %in% colnames(df))
      df <- df[order(df$P, na.last = TRUE), ]
    df_to_rows(df)
    
  }, error = function(e) {
    list(gene = gene, error = e$message)
  })
}


## ════════════════════════════════════════════════════════════════════════════
## ENDPOINT 7: get_maf_by_impact
## ════════════════════════════════════════════════════════════════════════════

#* Get minor allele frequencies for variants in a gene, grouped by impact
#*
#* Computes MAF directly from the genotype matrix via rvat, accounting for
#* ploidy and sex chromosomes. More accurate than the AF column in varInfo.
#* Returns per-variant MAF with variant annotation.
#*
#* @param gene Gene name (required).
#* @param impact_filter Variant filter: any (default), high, moderate,
#*                      high_moderate, synonymous.
#* @post /get_maf_by_impact
function(gene, impact_filter = "any", res = NULL) {
  tryCatch({
    if (is.null(gene) || gene == "")
      return(list(error = "gene parameter is required"))
    
    vsf_path <- make_varset(gene, impact_filter)
    vsf      <- varSetFile(vsf_path)
    vs       <- tryCatch(getVarSet(vsf, unit = gene), error = function(e) NULL)
    
    if (is.null(vs) || length(vs) == 0)
      return(list(gene = gene, error = "No variants found"))
    
    GT  <- getGT(db, varSet = vs, cohort = "pheno")
    maf <- getMAF(GT)
    af  <- getAF(GT)
    mac <- getMAC(GT)
    nc  <- getNCarriers(GT)
    
    ## Combine with variant annotation
    anno <- as.data.frame(rowData(GT))
    df   <- data.frame(
      VAR_id      = rownames(GT),
      gene_name   = if ("gene_name" %in% colnames(anno)) anno$gene_name else gene,
      MAF         = round(maf, 6),
      AF          = round(af, 6),
      MAC         = mac,
      nCarriers   = nc,
      HighImpact  = if ("HighImpact"   %in% colnames(anno)) anno$HighImpact   else NA,
      ModImpact   = if ("ModerateImpact" %in% colnames(anno)) anno$ModerateImpact else NA,
      Synonymous  = if ("Synonymous"   %in% colnames(anno)) anno$Synonymous   else NA,
      CADDphred   = if ("CADDphred"    %in% colnames(anno)) anno$CADDphred    else NA,
      stringsAsFactors = FALSE
    )
    ## Sort by MAF descending
    df <- df[order(df$MAF, decreasing = TRUE), ]
    ## Summary stats
    summary_row <- data.frame(
      VAR_id    = "SUMMARY",
      gene_name = gene,
      MAF       = round(mean(maf, na.rm = TRUE), 6),
      AF        = round(mean(af,  na.rm = TRUE), 6),
      MAC       = sum(mac, na.rm = TRUE),
      nCarriers = sum(nc,  na.rm = TRUE),
      HighImpact = NA, ModImpact = NA, Synonymous = NA, CADDphred = NA,
      stringsAsFactors = FALSE
    )
    df <- rbind(summary_row, df)
    df_to_rows(df)
    
  }, error = function(e) {
    list(gene = gene, error = e$message)
  })
}


## ════════════════════════════════════════════════════════════════════════════
## ENDPOINT 8: get_ld_matrix
## ════════════════════════════════════════════════════════════════════════════

#* Compute linkage disequilibrium (correlation) matrix for variants in a gene
#*
#* Uses rvat buildCorMatrix to compute pairwise LD (r-squared) between variants.
#* Returns the top correlated variant pairs. Makes U07 (LD questions) answerable.
#*
#* @param gene Gene name (required).
#* @param impact_filter Variant filter: high (default), moderate, any.
#* @param min_r2 Minimum r-squared to report (default 0.1). Set lower to see more pairs.
#* @post /get_ld_matrix
function(gene, impact_filter = "high", min_r2 = 0.1, res = NULL) {
  tryCatch({
    if (is.null(gene) || gene == "")
      return(list(error = "gene parameter is required"))
    
    vsf_path <- make_varset(gene, impact_filter)
    vsf      <- varSetFile(vsf_path)
    vs       <- tryCatch(getVarSet(vsf, unit = gene), error = function(e) NULL)
    
    if (is.null(vs) || length(vs) == 0)
      return(list(gene = gene, error = "No variants found"))
    
    GT  <- getGT(db, varSet = vs, cohort = "pheno")
    
    if (nrow(GT) < 2)
      return(list(gene = gene, message = "Fewer than 2 variants — LD cannot be computed"))
    
    ## Build correlation matrix
    cor_mat <- buildCorMatrix(GT)
    
    ## Extract upper triangle as pairs
    n    <- nrow(cor_mat)
    vars <- rownames(cor_mat)
    pairs <- data.frame(
      VAR_id_1 = character(0),
      VAR_id_2 = character(0),
      r2       = numeric(0),
      stringsAsFactors = FALSE
    )
    for (i in seq_len(n - 1)) {
      for (j in seq(i + 1, n)) {
        r2 <- cor_mat[i, j]^2
        if (!is.na(r2) && r2 >= as.numeric(min_r2)) {
          pairs <- rbind(pairs, data.frame(
            VAR_id_1 = vars[i],
            VAR_id_2 = vars[j],
            r2       = round(r2, 4),
            stringsAsFactors = FALSE
          ))
        }
      }
    }
    
    if (nrow(pairs) == 0)
      return(list(
        gene    = gene,
        message = paste0("No variant pairs with r2 >= ", min_r2,
                         " found among ", n, " variants in ", gene),
        n_variants_tested = n
      ))
    
    ## Sort by r2 descending
    pairs <- pairs[order(pairs$r2, decreasing = TRUE), ]
    df_to_rows(pairs)
    
  }, error = function(e) {
    list(gene = gene, error = e$message)
  })
}


## ════════════════════════════════════════════════════════════════════════════
## ENDPOINT 9: get_cohort_summary
## ════════════════════════════════════════════════════════════════════════════

#* Get cohort/sample summary from the rvat gdb
#*
#* Returns sample counts, phenotype distribution, sex distribution, and
#* population breakdown directly from the rvat cohort table.
#*
#* @get /get_cohort_summary
function(res = NULL) {
  tryCatch({
    pheno <- getCohort(db, cohort = "pheno")
    pheno_df <- as.data.frame(pheno)
    
    ## Summary counts
    n_total   <- nrow(pheno_df)
    n_cases   <- sum(pheno_df$pheno == 1, na.rm = TRUE)
    n_controls <- sum(pheno_df$pheno == 0, na.rm = TRUE)
    
    sex_col  <- if ("sex" %in% colnames(pheno_df)) pheno_df$sex else NULL
    n_female <- if (!is.null(sex_col)) sum(sex_col == 1, na.rm = TRUE) else NA
    n_male   <- if (!is.null(sex_col)) sum(sex_col == 2, na.rm = TRUE) else NA
    
    pop_col  <- if ("superPop" %in% colnames(pheno_df)) pheno_df$superPop else NULL
    pop_counts <- if (!is.null(pop_col)) as.list(table(pop_col)) else list()
    
    list(
      n_total    = n_total,
      n_cases    = n_cases,
      n_controls = n_controls,
      n_female   = n_female,
      n_male     = n_male,
      pop_counts = pop_counts,
      columns_available = paste(colnames(pheno_df), collapse = ", ")
    )
  }, error = function(e) {
    list(error = e$message)
  })
}

#* @get /status
function(res = NULL) {
  list(
    status       = "ok",
    rvat_version = as.character(packageVersion("rvat")),
    gdb_path     = GDB_PATH,
    cohort       = "pheno",
    anno         = "varInfo",
    message      = "rvat server running. Use /run_burden_test, /run_burden_all_genes, /get_variant_summary, /get_carrier_info"
  )
}