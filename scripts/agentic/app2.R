# ─────────────────────────────────────────────────────────────────────────────
# Project ALS  —  Variant Assistant v2 (Agentic Pipeline)
# Packages : shiny, bslib, DT, httr2, jsonlite, shinyjs
# Requires : mcpo on localhost:8008 (4 servers)  |  Ollama on localhost:11434
#
# Architecture:
#   classify_complexity() → "simple" or "complex"
#   simple  → run_single_pipeline() / run_dual_pipeline() (unchanged from app.R)
#   complex → run_agentic_pipeline() (multi-step, multi-server tool loop)
# ─────────────────────────────────────────────────────────────────────────────

library(shiny)
library(bslib)
library(DT)
library(httr2)
library(jsonlite)
library(shinyjs)

## ── Config ───────────────────────────────────────────────────────────────────
MCP_BASE   <- "http://localhost:8008"
OLLAMA_URL <- "http://localhost:11434"
ORCH_MODEL <- "llama3.1:8b"
MAX_STEPS  <- 5   ## agentic loop max iterations

## ── MCP server prefixes ──────────────────────────────────────────────────────
MCP_SERVERS <- list(
  db          = "db_exploration",
  variant     = "variant_analysis",
  genotype    = "genotype_analysis",
  phenotype   = "phenotype_data"
)

## ── Prompts ──────────────────────────────────────────────────────────────────
`%||%` <- function(a, b) if (!is.null(a)) a else b

load_prompts <- function() {
  prompts_file <- file.path(getwd(), "prompts.txt")
  if (!file.exists(prompts_file)) {
    message("WARNING: prompts.txt not found")
    return(list(data_description = "", extra_instructions = ""))
  }
  raw   <- paste(readLines(prompts_file, warn = FALSE), collapse = "\n")
  parts <- strsplit(raw, "===EXTRA_INSTRUCTIONS===")[[1]]
  data_desc  <- trimws(sub(".*===DATA_DESCRIPTION===\n", "", parts[1]))
  extra_inst <- if (length(parts) > 1) trimws(parts[2]) else ""
  extra_short <- strsplit(extra_inst, "EXAMPLES:")[[1]][1]
  list(
    data_description   = data_desc,
    extra_instructions = trimws(extra_short %||% extra_inst)
  )
}

PROMPTS <- load_prompts()

AVAILABLE_MODELS <- list(
  single_llama = list(
    mode = "single", orch = ORCH_MODEL, sub = NULL,
    label = "Single — llama3.1:8b",
    desc  = "Fast. Good tool selection, auto-routes simple/complex."
  ),
  dual_duckdb = list(
    mode = "dual", orch = ORCH_MODEL, sub = "duckdb-nsql",
    label = "Two LLM — llama3.1 + duckdb-nsql ★",
    desc  = "SQL specialist activates for run_variant_query. Best for complex SQL."
  ),
  dual_llama = list(
    mode = "dual", orch = ORCH_MODEL, sub = ORCH_MODEL,
    label = "Two LLM — llama3.1 + llama3.1",
    desc  = "Both steps use same model. Good for reasoning-heavy questions."
  ),
  dual_adaptive = list(
    mode = "dual_adaptive", orch = ORCH_MODEL,
    sub_sql = "duckdb-nsql", sub_reason = ORCH_MODEL,
    label = "Adaptive — llama3.1 + [duckdb-nsql | llama3.1] ★",
    desc  = "LLM1 selects: duckdb-nsql for SQL queries, llama3.1 for tool reasoning."
  )
)

# ══════════════════════════════════════════════════════════════════════════════
# HELPERS
# ══════════════════════════════════════════════════════════════════════════════

call_mcp <- function(server_prefix, tool_name, body = list()) {
  url <- paste0(MCP_BASE, "/", server_prefix, "/", tool_name)
  tryCatch({
    resp <- request(url) |>
      req_body_json(body) |>
      req_timeout(30) |>
      req_perform()
    resp_body_string(resp)
  }, error = function(e) toJSON(list(error = e$message), auto_unbox = TRUE))
}

call_ollama <- function(prompt, system_prompt = NULL, model = ORCH_MODEL,
                        json_mode = FALSE, num_predict = 600, retries = 2L) {
  ## Retry logic for transient Ollama failures
  for (attempt in seq_len(retries + 1L)) {
    result <- tryCatch(
      call_ollama_once(prompt, system_prompt, model, json_mode, num_predict),
      error = function(e) structure(list(error = e$message), class = "ollama_error")
    )
    if (!inherits(result, "ollama_error")) return(result)
    if (attempt <= retries) {
      cat("[OLLAMA] Attempt", attempt, "failed, retrying in 3s...\n")
      Sys.sleep(3)
    }
  }
  paste0("Ollama not reachable: ", result$error)
}

call_ollama_once <- function(prompt, system_prompt = NULL, model = ORCH_MODEL,
                             json_mode = FALSE, num_predict = 600) {
  body <- list(model = model, prompt = prompt, stream = FALSE,
               options = list(temperature = if (json_mode) 0.0 else 0.2,
                              num_predict = num_predict))
  if (!is.null(system_prompt)) body$system <- system_prompt
  if (json_mode)               body$format <- "json"
  tryCatch({
    resp <- request(OLLAMA_URL) |>
      req_url_path("/api/generate") |>
      req_body_json(body) |>
      req_timeout(120) |>
      req_perform()
    resp_body_json(resp)$response
  }, error = function(e) paste("Ollama not reachable:", e$message))
}

parse_json_response <- function(raw) {
  tryCatch({
    clean <- gsub("```json|```", "", raw)
    clean <- trimws(clean)
    start <- regexpr("\\{", clean)[[1]]
    end   <- tail(gregexpr("\\}", clean)[[1]], 1)
    if (start > 0 && end > start) clean <- substr(clean, start, end)
    fromJSON(clean, simplifyVector = FALSE)
  }, error = function(e) NULL)
}

check_mcp_error <- function(raw) {
  parsed <- tryCatch(fromJSON(raw, simplifyVector = FALSE), error = function(e) NULL)
  if (!is.null(parsed$error)) parsed$error else NULL
}

result_to_df <- function(raw) {
  tryCatch({
    parsed <- fromJSON(raw, flatten = TRUE)
    if (is.data.frame(parsed)) return(parsed)
    if (is.list(parsed) && length(parsed) > 0) {
      flat <- unlist(parsed, recursive = TRUE)
      return(data.frame(key = names(flat), value = as.character(unname(flat)),
                        stringsAsFactors = FALSE))
    }
    data.frame(result = as.character(raw))
  }, error = function(e) data.frame(result = raw))
}

# ══════════════════════════════════════════════════════════════════════════════
# TOOL DESCRIPTIONS — organised by server
# ══════════════════════════════════════════════════════════════════════════════

TOOL_DESCRIPTIONS_SIMPLE <- paste(
  "Available tools (prefix/tool_name):\n",
  "variant_analysis/count_variants_in_gene      — count variants in a gene | params: {gene}\n",
  "variant_analysis/get_high_impact_variants_in_gene — high-impact + CADD | params: {gene, cadd_min}\n",
  "variant_analysis/count_sift_deleterious_in_gene   — SIFT deleterious | params: {gene}\n",
  "variant_analysis/get_top_deleterious_in_gene       — top N deleterious | params: {gene, top_n}\n",
  "variant_analysis/get_highest_af_variant            — highest AF | params: {}\n",
  "variant_analysis/get_average_af_by_impact          — avg AF by impact | params: {}\n",
  "variant_analysis/summarize_variants_by_gene        — gene summary | params: {min_variants}\n",
  "genotype_analysis/get_high_impact_homozygous_ALS   — homozygous ALS | params: {}\n",
  "genotype_analysis/get_total_burden_cases_vs_controls — burden | params: {gene}\n",
  "genotype_analysis/get_carriers_by_gene             — carriers | params: {gene, group}\n",
  "genotype_analysis/get_dosage_ratio_by_gene         — case/control ratio | params: {}\n",
  "genotype_analysis/get_case_enriched_variants       — case-enriched | params: {top_n}\n",
  "db_exploration/get_database_limitations            — what is NOT available | params: {}\n",
  "db_exploration/get_database_info                   — database overview, ALS cases vs controls count | params: {}\n",
  "phenotype_data/get_age_distribution                — average age of ALS cases and controls | params: {}\n",
  "variant_analysis/get_als_carrier_stats             — % variants carried by \u22651 ALS patient | params: {}\n",
  "variant_analysis/run_variant_query                 — free SQL on varInfo_synthetic | params: {sql}\n",
  sep = ""
)

TOOL_DESCRIPTIONS_COMPLEX <- paste(
  TOOL_DESCRIPTIONS_SIMPLE,
  "clinvar_annotation/get_clinvar_for_variant       — ClinVar significance for a specific VAR_id | params: {var_id}\n",
  "clinvar_annotation/get_clinvar_for_gene          — ClinVar records for all variants in a gene | params: {gene, sig_filter}\n",
  "clinvar_annotation/get_clinvar_summary_by_gene   — how many variants have ClinVar records | params: {}\n",
  "rvat_analysis/run_burden_test                    — statistical burden test for one gene | params: {gene, test, impact_filter, max_af, covar}\n",
  "rvat_analysis/run_burden_all_genes               — burden test across all 12 genes, ranked by p-value | params: {test, impact_filter}\n",
  "rvat_analysis/run_single_variant_test            — per-variant p-values for a gene | params: {gene, test, impact_filter}\n",
  "rvat_analysis/get_maf_by_impact                  — MAF per variant in a gene from rvat genotype matrix | params: {gene, impact_filter}\n",
  "rvat_analysis/get_ld_matrix                      — linkage disequilibrium (r2) between variants | params: {gene, impact_filter, min_r2}\n",
  "rvat_analysis/get_variant_summary                — per-variant genotype stats via rvat | params: {gene, impact_filter}\n",
  "rvat_analysis/get_carrier_info                   — sample-level carrier info from rvat | params: {gene, impact_filter, var_id}\n",
  "rvat_analysis/get_cohort_summary                 — sample counts, sex/pop distribution from rvat | params: {}\n",
  "phenotype_data/get_sex_distribution              — sex breakdown of all samples | params: {}\n",
  "phenotype_data/get_population_counts             — samples per population | params: {}\n",
  "phenotype_data/get_carriers_with_phenotype       — carriers with sex/age/pop | params: {gene, impact, sex, population}\n",
  "phenotype_data/get_age_distribution              — average age of ALS cases and controls | params: {}\n",
  "phenotype_data/run_phenotype_query               — free SQL on pheno/SM | params: {sql}\n",
  "db_exploration/get_database_info                 — total ALS cases vs controls count | params: {}\n",
  "genotype_analysis/get_pathogenic_burden_by_gene — pathogenic burden | params: {sample_id}\n",
  sep = ""
)

# ══════════════════════════════════════════════════════════════════════════════
# COMPLEXITY CLASSIFIER
# ══════════════════════════════════════════════════════════════════════════════

classify_complexity <- function(question) {
  complex_keywords <- c(
    "female", "male", "sex", "population", "cohort",
    "SAS", "EUR", "AFR", "EAS", "AMR", "pheno",
    "female carrier", "male carrier", "women", "men"
  )
  q_lower <- tolower(question)
  for (kw in complex_keywords) {
    if (grepl(tolower(kw), q_lower, fixed = TRUE)) {
      return("complex")
    }
  }
  
  sys <- paste0(
    "You classify genomic database questions as 'simple' or 'complex'.\n",
    "Output ONLY one word: simple OR complex. Nothing else.\n\n",
    "Complex: questions needing sex, age, population, or sample phenotype data.\n",
    "Simple: variant counts, impact, allele frequency, burden, gene summaries."
  )
  raw <- call_ollama(question, system_prompt = sys,
                     model = ORCH_MODEL, num_predict = 5)
  raw <- trimws(tolower(raw))
  if (grepl("complex", raw)) "complex" else "simple"
}

# ══════════════════════════════════════════════════════════════════════════════
# CLASSIFY TOOL (for simple pipeline)
# ══════════════════════════════════════════════════════════════════════════════

classify_tool <- function(question, orch_model = ORCH_MODEL,
                          tool_desc = TOOL_DESCRIPTIONS_SIMPLE) {
  sys <- paste0(
    PROMPTS$data_description, "\n\n",
    PROMPTS$extra_instructions, "\n\n",
    "Output ONLY a valid JSON with exactly two keys: 'server' and 'tool' and 'params'.\n",
    "Use the format: {\"server\": \"variant_analysis\", \"tool\": \"count_variants_in_gene\", \"params\": {\"gene\": \"NEK1\"}}\n",
    "No explanation. No markdown. No extra text.\n\n",
    tool_desc, "\n",
    "RULES:\n",
    "- Gene names always uppercase: NEK1, SOD1, TARDBP, FUS, ABCA4\n",
    "- 'Select/show variants' = get_high_impact_variants_in_gene\n",
    "- 'Count/how many variants' in a gene = count_variants_in_gene (always needs gene param)\n",
    "- 'How many SIFT tolerated / SIFT=T across all genes' = run_variant_query with SIFT=\'T\'\n",
    "- 'How many PolyPhen possibly damaging / PolyPhen=P' = run_variant_query\n",
    "  params: {sql: \"SELECT COUNT(*) as n FROM varInfo_synthetic WHERE PolyPhen=\'P\'\"}\n",
    "  NOTE: PolyPhen codes are single letters: D=damaging, P=possibly damaging, B=benign, .=missing\n",
    "- 'Which chromosome has most variants' = run_variant_query GROUP BY CHROM\n",
    "- HighImpact/ModerateImpact/Synonymous are TEXT: use HighImpact=\'1\' NOT HighImpact=1\n",
    "- CRITICAL column names: gene_name (NOT Gene), VAR_id (NOT variant_id), AF (NOT AlleleFrequency or allele_frequency)\n",
    "- ALS_1..ALS_5, Control_1..Control_5 are genotype columns (0=ref, 1=het, 2=hom)\n",
    "- CHROM values include 'chr' prefix: 'chrX' NOT 'X', 'chr1' NOT '1'\n",
    "- 'Variants both synonymous AND high impact' = run_variant_query\n",
    "  sql: SELECT COUNT(*) as n FROM varInfo_synthetic WHERE HighImpact=\'1\' AND Synonymous=\'1\'\n",
    "  Expected answer: 0 (mutually exclusive categories)\n",
    "- CRITICAL: correct column names are gene_name, VAR_id, AF — NEVER use Gene, variant_id, AlleleFrequency\n",
    "- CHROM values always have chr prefix: \'chrX\' not \'X\', \'chr1\' not \'1\'\n",
    "- For single-gene questions (FUS summary etc): use run_variant_query with WHERE gene_name=\'FUS\'\n",
    "  NOT summarize_variants_by_gene which returns ALL genes\n",
    "- CRITICAL: missing values are stored as \'.\' NOT NULL — use CADDphred!=\'.\' NOT IS NOT NULL\n",
    "  NEVER use IS NULL or IS NOT NULL for CADDphred, PolyPhen, SIFT, AF\n",
    "- ALWAYS use CAST(CADDphred AS REAL) for numeric comparisons e.g. CAST(CADDphred AS REAL)>30\n",
    "- ALWAYS use CAST(AF AS REAL) for AF comparisons and ORDER BY\n",
    "- ALS_1..ALS_5 and Control_1..Control_5 are genotype columns (integers), NOT gene names\n",
    "  To check carrier: ALS_4>0 means carries variant. ALS_4=1 means het, ALS_4=2 means hom\n",
    "- For CADD above threshold in a gene: WHERE gene_name=\'ABCA4\' AND CADDphred!=\'.\' AND CAST(CADDphred AS REAL)>30\n",
    "- For het/hom split: SELECT SUM(CASE WHEN ALS_4=1 THEN 1 ELSE 0 END) AS het, SUM(CASE WHEN ALS_4=2 THEN 1 ELSE 0 END) AS hom FROM varInfo_synthetic WHERE HighImpact=\'1\'\n",
    "- For variants shared by carriers: use >0 not =2 (=2 means homozygous only, >0 means any carrier)\n",
    "- ALS-only variants (not in any control): WHERE (ALS_1>0 OR ALS_2>0 OR ALS_3>0 OR ALS_4>0 OR ALS_5>0)\n",
    "  AND Control_1=0 AND Control_2=0 AND Control_3=0 AND Control_4=0 AND Control_5=0\n",
    "  NEVER use =2 to mean 'carried' — =2 means homozygous specifically\n",
    "- For CADD ordering: ORDER BY CAST(CADDphred AS REAL) DESC (not ORDER BY CADDphred which sorts text)\n",
    "- For AF ordering: ORDER BY CAST(AF AS REAL) ASC and WHERE AF!=\'.\' AND CAST(AF AS REAL)>0\n",
    "- For UNION queries: all SELECT parts must have same number of columns\n",
    "- For average CADD by impact: SELECT\n",
    "    AVG(CASE WHEN HighImpact=\'1\' THEN CAST(CADDphred AS REAL) END) AS avg_high,\n",
    "    AVG(CASE WHEN ModerateImpact=\'1\' THEN CAST(CADDphred AS REAL) END) AS avg_moderate\n",
    "  FROM varInfo_synthetic WHERE gene_name=\'NEK1\' AND CADDphred!=\'.\'\n",
    "- 'Which genes have more case burden / case enriched / more in cases / dosage ratio' = get_dosage_ratio_by_gene\n",
    "  server=genotype_analysis, tool=get_dosage_ratio_by_gene, params={}\n",
    "- 'What percentage of variants carried by ALS / how many variants carried by ALS patient' = get_als_carrier_stats\n",
    "  server=variant_analysis, tool=get_als_carrier_stats, params={}\n",
    "- 'How many ALS cases vs controls in database / total samples' = get_database_info\n",
    "- 'Average age / age distribution' = phenotype_data/get_age_distribution (server=phenotype_data)\n",
    "- 'Is variant X pathogenic / ClinVar / previously reported' = get_database_limitations\n",
    "- 'Allele frequency in Europeans/SAS/AFR/population-specific/in population X' = get_database_limitations\n",
    "- 'Is there a significant burden / association / enrichment / p-value for gene X' = rvat_analysis/run_burden_test\n",
    "  server=rvat_analysis, tool=run_burden_test, params: {gene: X, test: firth, impact_filter: high_moderate}\n",
    "  NEVER use run_variant_query for burden/association/significance questions — use rvat_analysis/run_burden_test\n",
    "- 'Which genes are most enriched in ALS / burden test all genes / run association' = rvat_analysis/run_burden_all_genes\n",
    "- 'MAF / minor allele frequency / allele frequency for variants in gene X' = rvat_analysis/get_maf_by_impact\n",
    "  server=rvat_analysis, tool=get_maf_by_impact, params={gene: X, impact_filter: moderate}\n",
    "  NEVER use get_average_af_by_impact for gene-specific MAF — that returns global averages\n",
    "  NEVER use run_variant_query for MAF questions when gene is specified — use rvat_analysis/get_maf_by_impact\n",
    "- 'Linkage disequilibrium / LD / r2 / correlation between variants' = rvat_analysis/get_ld_matrix\n",
    "- 'Which specific variants are most associated / single variant test / per variant p-value' = rvat_analysis/run_single_variant_test\n",
    "- 'Is VAR_id X pathogenic / previously reported / ClinVar' = get_clinvar_for_variant\n",
    "  server=clinvar_annotation, tool=get_clinvar_for_variant, params={var_id: <INTEGER from question>}\n",
    "  ONLY call get_clinvar_for_variant when a SPECIFIC VAR_id number is given\n",
    "  NEVER hallucinate a var_id — if no specific number is in the question, use get_database_limitations\n",
    "- 'Which variants are clinically significant' (no specific VAR_id) = get_database_limitations\n",
    "  server=db_exploration, tool=get_database_limitations, params={}\n",
    "  Reason: no clinical classification system in database — ClinVar covers only specific queried variants\n",
    "- 'What is the rs-number of VAR_id X' = run_variant_query SELECT ID FROM varInfo_synthetic WHERE VAR_id=X\n",
    "- 'Age of onset / earliest onset / disease progression / severity / causative / wet-lab / de novo / linkage disequilibrium / protein domain / population-specific AF' = get_database_limitations\n",
    "  NEVER call get_highest_af_variant for population-specific questions — that returns global AF only\n",
    "- NEVER use IS NOT NULL for CADDphred/PolyPhen/SIFT\n",
    "- NEVER call count_variants_in_gene without a gene param\n",
    "- \'Total variants in dataset\' / \'how many variants total\': run_variant_query\n",
    "  sql: SELECT COUNT(*) as n FROM varInfo_synthetic\n",
    "- Per-sample high-impact burden (ALS_5 vs Control_5 etc): run_variant_query\n",
    "  sql: SELECT SUM(ALS_5) AS als5_burden, SUM(Control_5) AS ctrl5_burden FROM varInfo_synthetic WHERE HighImpact=\'1\'\n",
    "- Highest control burden per sample: run_variant_query\n",
    "  sql: SELECT SUM(Control_1) AS C1, SUM(Control_2) AS C2, SUM(Control_3) AS C3, SUM(Control_4) AS C4, SUM(Control_5) AS C5 FROM varInfo_synthetic WHERE HighImpact=\'1\'\n",
    "\n",
    "Return ONLY JSON for: ", question
  )
  raw <- call_ollama(question, system_prompt = sys,
                     model = orch_model, json_mode = TRUE)
  parsed <- parse_json_response(raw)
  if (is.null(parsed) || is.null(parsed$tool)) {
    return(list(ok = FALSE, error = paste("Classification failed:", raw)))
  }
  tool_raw   <- parsed$tool
  server_raw <- parsed$server %||% ""
  if (grepl("/", tool_raw)) {
    parts  <- strsplit(tool_raw, "/")[[1]]
    server <- parts[1]
    tool   <- paste(parts[-1], collapse = "/")
  } else if (grepl("/", server_raw)) {
    parts  <- strsplit(server_raw, "/")[[1]]
    server <- tail(parts, 1)
    tool   <- tool_raw
  } else {
    server <- if (nchar(server_raw) > 0) server_raw else "variant_analysis"
    tool   <- tool_raw
  }
  raw_params <- if (is.null(parsed$params)) list() else as.list(parsed$params)
  raw_params <- raw_params[!sapply(raw_params, function(v) is.null(v) || identical(v, ""))]
  list(ok = TRUE, server = server, tool = tool, params = raw_params)
}

# ══════════════════════════════════════════════════════════════════════════════
# SUMMARISE
# ══════════════════════════════════════════════════════════════════════════════

summarize_result <- function(question, steps_log, result_json,
                             row_count = NULL, orch_model = ORCH_MODEL) {
  sys <- paste0(
    PROMPTS$data_description, "\n\n",
    "You are an ALS bioinformatics assistant. ",
    "Give a short, clear English summary (max 3 sentences). ",
    "Do not use SQL, JSON or technical jargon. ",
    "Start directly with the conclusion. ",
    "Always mention exact numbers when you know them. ",
    "IMPORTANT: Always respond in English only. ",
    "IMPORTANT: The AF column is GLOBAL allele frequency only. ",
    "Never report it as a population-specific frequency (e.g. European AF). ",
    "If asked for population-specific AF, state it is not available."
  )
  preview <- if (nchar(result_json) > 3000) {
    paste0(substr(result_json, 1, 3000), "\n... [result shortened]")
  } else result_json
  count_hint <- if (!is.null(row_count)) {
    paste0("\nThe exact number of rows found is: ", row_count, ". Always mention this.\n")
  } else ""
  tools_called <- paste(steps_log, collapse = " ")
  
  limitations_note <- if (grepl("get_database_limitations", tools_called)) {
    paste0(
      "IMPORTANT: The tool returned database limitations.\n",
      "This means the requested data does NOT EXIST in this database.\n",
      "Do NOT say it was searched and came up empty.\n",
      "Do NOT mention ClinVar as if it was queried.\n",
      "Simply state clearly: this information is not available.\n",
      "Keep the response to 2 sentences maximum.\n\n"
    )
  } else if (grepl("get_carriers_with_phenotype", tools_called)) {
    paste0(
      "IMPORTANT: The result contains one ROW per carrier individual.\n",
      "The NUMBER OF CARRIERS = number of rows returned (count the IID entries).\n",
      "n_qualifying_variants is how many variants that person carries, NOT the carrier count.\n",
      "State: There are X carriers, where X equals the number of rows shown.\n\n"
    )
  } else if (grepl("get_total_burden_cases_vs_controls", tools_called)) {
    paste0(
      "IMPORTANT: total_cases_burden and total_controls_burden are ALLELE BURDEN totals\n",
      "(sum of all genotype values across all variants), NOT counts of variants or carriers.\n",
      "Do NOT convert these to percentages unless explicitly asked.\n\n"
    )
  } else if (grepl("get_age_distribution", tools_called)) {
    paste0(
      "IMPORTANT: The result has two rows.\n",
      "For average age of ALS cases, use mean_age from the row where group_label is ALS case.\n",
      "The first row (group_label null) is the overall population, not just ALS cases.\n\n"
    )
  } else if (grepl("get_als_carrier_stats", tools_called)) {
    paste0(
      "IMPORTANT: pct_carried_by_als is the percentage of variants carried by at least one ALS patient.\n",
      "carried_by_als is the count of such variants. als_only is variants found ONLY in ALS cases.\n\n"
    )
  } else if (grepl("summarize_variants_by_gene", tools_called)) {
    paste0(
      "IMPORTANT: summarize_variants_by_gene returns ALL genes.\n",
      "Find the row matching the requested gene_name and report only that row values.\n\n"
    )
  } else ""
  
  ## Truncate very large results to prevent Ollama context overflow
  ## Keep first 3000 chars — enough for 12 burden test rows or 20+ variant rows
  MAX_PREVIEW_CHARS <- 3000L
  if (nchar(preview) > MAX_PREVIEW_CHARS) {
    n_chars <- nchar(preview)
    preview <- paste0(
      substr(preview, 1, MAX_PREVIEW_CHARS),
      "\n... [truncated ", n_chars - MAX_PREVIEW_CHARS, " chars — summarise from data shown above]"
    )
  }
  
  prompt <- paste0(
    "[Respond in English only. Do not use Dutch.]\n\n",
    limitations_note,
    "IMPORTANT: If the result contains rows with IID, sex_label, phenotype_label fields,\n",
    "each ROW = one carrier. The number of carriers = number of rows, NOT n_qualifying_variants.\n",
    "n_qualifying_variants is the count of variants that sample carries, not the carrier count.\n\n",
    "User question: ", question, "\n",
    "Steps taken: ", paste(steps_log, collapse = " \u2192 "), "\n",
    count_hint,
    "Final result:\n", preview, "\n\n",
    "Write a short 2-3 sentence answer in English. Start with the conclusion."
  )
  call_ollama(prompt, system_prompt = sys, model = orch_model)
}

# ══════════════════════════════════════════════════════════════════════════════
# AGENTIC PIPELINE
# ══════════════════════════════════════════════════════════════════════════════

extract_entities <- function(question) {
  q <- toupper(question)
  genes <- c("NEK1","SOD1","TARDBP","FUS","ABCA4","OPTN","TBK1",
             "C9ORF72","UBQLN2","VCP","PEX5","RIN3","IL3RA",
             "ZNF483","CYP19A1","UBQLN2")
  found_gene <- NA
  for (g in genes) {
    if (grepl(g, q, fixed = TRUE)) { found_gene <- g; break }
  }
  sex_val <- NA
  if (grepl("\\bFEMALE\\b|\\bWOMAN\\b|\\bWOMEN\\b", q, perl = TRUE)) sex_val <- 1L
  if (grepl("\\bMALE\\b|\\bMAN\\b|\\bMEN\\b", q, perl = TRUE) &&
      !grepl("\\bFEMALE\\b|\\bWOMAN\\b|\\bWOMEN\\b", q, perl = TRUE)) sex_val <- 2L
  pops <- c("SAS","EUR","AFR","EAS","AMR")
  found_pop <- NA
  for (p in pops) {
    if (grepl(paste0("\\b", p, "\\b"), q, perl = TRUE)) { found_pop <- p; break }
  }
  list(gene = found_gene, sex = sex_val, population = found_pop)
}

is_unanswerable <- function(question) {
  q <- tolower(question)
  unanswerable_patterns <- c(
    "validated", "wet.lab", "wet lab", "experimental",
    "haplotype", "phase",
    "de novo", "de-novo", "parental",
    "age of onset", "onset", "disease progression", "progression",
    "protein domain", "domain affected",
    "rs.number", "rsid", "dbsnp",
    "literature",
    "causative for", "cause.*als", "als.*cause",
    "strongest effect.*risk", "effect.*disease risk",
    "allele frequency.*european", "allele frequency.*african",
    "allele frequency.*asian", "allele frequency.*population",
    "frequency.*in.*eur\\b", "frequency.*in.*afr\\b",
    "frequency.*in.*sas\\b", "frequency.*in.*eas\\b",
    "population.specific.*frequency", "frequency.*population.specific",
    "how long.*diagnosed", "duration.*diagnosis",
    "most severe", "severity"
  )
  for (pat in unanswerable_patterns) {
    if (grepl(pat, q, perl = TRUE)) return(TRUE)
  }
  FALSE
}

run_agentic_pipeline <- function(question, orch_model = ORCH_MODEL,
                                 progress_fn = NULL) {
  steps_log   <- character(0)
  last_result <- ""
  last_df     <- NULL
  
  ## Hard pre-check
  if (is_unanswerable(question)) {
    cat("[AGENTIC] Pre-check: question flagged as unanswerable, routing to limitations\n")
    raw_result  <- call_mcp("db_exploration", "get_database_limitations", list())
    steps_log   <- "db_exploration/get_database_limitations"
    last_result <- raw_result
    last_df     <- result_to_df(raw_result)
    if (!is.null(progress_fn)) progress_fn("Formulating answer...", MAX_STEPS + 1)
    summary_text <- summarize_result(question, steps_log, raw_result,
                                     NULL, orch_model = orch_model)
    return(list(ok = TRUE, text = summary_text, tool = steps_log, params = list(),
                df = last_df, mode = "agentic", steps = 1, steps_log = steps_log,
                complexity = "unanswerable_precheck"))
  }
  
  entities <- extract_entities(question)
  entity_hint <- paste0(
    "Extracted entities from the question:\n",
    if (!is.na(entities$gene))       paste0("  gene = '", entities$gene, "'\n") else "",
    if (!is.na(entities$sex))        paste0("  sex = ", entities$sex,
                                            " (", if (entities$sex == 1) "female" else "male", ")\n") else "",
    if (!is.na(entities$population)) paste0("  population = '", entities$population, "'\n") else "",
    "Use these EXACT values in your tool params.\n"
  )
  
  context     <- entity_hint
  best_result <- ""
  best_df     <- NULL
  best_params <- list()
  
  cat("\n[AGENTIC] Question:", question, "\n")
  cat("[AGENTIC] Entities — gene:", entities$gene,
      " sex:", entities$sex, " pop:", entities$population, "\n")
  
  ## Dynamic step budget
  q_lower       <- tolower(question)
  is_counting_q <- grepl("how many|count|total|number of", q_lower)
  is_lookup_q   <- grepl("what is the|which variant|list all|show me", q_lower)
  step_budget   <- if (is_counting_q || is_lookup_q) 3L else MAX_STEPS
  cat("[AGENTIC] Step budget:", step_budget, "\n")
  
  for (step in seq_len(step_budget)) {
    if (!is.null(progress_fn))
      progress_fn(paste0("Agentic step ", step, "/", MAX_STEPS, "..."), step)
    
    step_sys <- paste0(
      PROMPTS$data_description, "\n\n",
      "You are an ALS bioinformatics assistant with access to multiple tools.\n",
      "Select the NEXT tool needed to answer the question.\n",
      "If you have enough information to answer, output: ",
      "{\"status\": \"final\", \"server\": null, \"tool\": null, \"params\": {}}\n\n",
      TOOL_DESCRIPTIONS_COMPLEX, "\n",
      "RULES:\n",
      "- Gene names uppercase: NEK1, SOD1, TARDBP, FUS, ABCA4\n",
      "- IID mapping: ALS_1 column = IID 'ALS1' in pheno table\n",
      "- sex param MUST be integer: 1 for female, 2 for male. NEVER pass 'female' or 'male' as string.\n",
      "- CRITICAL: HighImpact, ModerateImpact, Synonymous are stored as TEXT '0' or '1', NOT integers.\n",
      "- CRITICAL column names in varInfo_synthetic: gene_name, VAR_id, AF, CHROM, POS, REF, ALT\n",
      "  NEVER use: Gene, gene, variant_id, AlleleFrequency, allele_frequency, individual, case_control\n",
      "- CHROM values: 'chr1', 'chrX' etc — always include 'chr' prefix\n",
      "- For DISTINCT gene list: SELECT DISTINCT gene_name (not just SELECT gene_name)\n",
      "- For het/hom split for a specific sample (e.g. ALS_4): run_variant_query\n",
      "  sql: SELECT\n",
      "    SUM(CASE WHEN ALS_4=1 AND HighImpact=\'1\' THEN 1 ELSE 0 END) AS heterozygous,\n",
      "    SUM(CASE WHEN ALS_4=2 AND HighImpact=\'1\' THEN 1 ELSE 0 END) AS homozygous\n",
      "  FROM varInfo_synthetic\n",
      "  NEVER call get_burden_per_sample without a valid sample_id\n",
      "- For single-gene summary (FUS, UBQLN2 etc): use run_variant_query NOT summarize_variants_by_gene\n",
      "  EXACT SQL (replace FUS with target gene):\n",
      "  SELECT COUNT(*) AS total_variants,\n",
      "    SUM(CASE WHEN HighImpact=\'1\' THEN 1 ELSE 0 END) AS high_impact,\n",
      "    SUM(CASE WHEN ModerateImpact=\'1\' THEN 1 ELSE 0 END) AS moderate_impact,\n",
      "    SUM(CASE WHEN Synonymous=\'1\' THEN 1 ELSE 0 END) AS synonymous,\n",
      "    ROUND(AVG(CASE WHEN AF!=\'.\'  THEN CAST(AF AS REAL) END),8) AS mean_AF\n",
      "  FROM varInfo_synthetic WHERE gene_name=\'FUS\'\n",
      "- pheno table coding: pheno=1 is ALS case, pheno=0 is control (NOT pheno=2)\n",
      "- rvat_analysis impact_filter valid values: any, high, moderate, high_moderate, synonymous\n",
      "  NEVER use column names like ModerateImpact, HighImpact, Synonymous as impact_filter values\n",
      "- For 'Is VAR_id X pathogenic/reported/ClinVar': clinvar_annotation/get_clinvar_for_variant\n",
      "  params: {var_id: <integer>} — ONLY when a specific VAR_id number is in the question\n",
      "  e.g. 'Is VAR_id 1277 pathogenic' → {var_id: 1277}\n",
      "- For vague pathogenicity questions ('which variants are clinically significant'):  get_database_limitations\n",
      "  Reason: no genome-wide clinical classification — ClinVar only works for specific variants\n",
      "  NEVER invent a var_id to call get_clinvar_for_variant\n",
      "- For 'carriers with pathogenic/high-impact mutations in gene X in population Y': SINGLE STEP\n",
      "  Use: phenotype_data/get_carriers_with_phenotype\n",
      "  params: {gene: X, impact: high_moderate, sex: <1 or 2 if specified>, population: Y}\n",
      "  impact param only accepts: high, moderate, high_moderate, any — NEVER 'pathogenic'\n",
      "  'Pathogenic mutation' = use impact=high_moderate as proxy (standard genomics approach)\n",
      "  Do NOT call ClinVar for carrier questions — use get_carriers_with_phenotype directly\n",
      "  NOTE: Only 5 ALS samples + 5 controls = max 10 carriers total in this dataset\n",
      "- For rs-number questions: check the ID column in varInfo_synthetic first with run_variant_query\n",
      "  e.g. SELECT ID, VAR_id FROM varInfo_synthetic WHERE VAR_id=200\n",
      "- 'Variants that are both synonymous AND high impact': this IS answerable \u2014 run_variant_query\n",
      "  sql: SELECT COUNT(*) as n FROM varInfo_synthetic WHERE HighImpact=\'1\' AND Synonymous=\'1\'\n",
      "  The correct answer is 0 because these categories are mutually exclusive.\n",
      "  Always use: WHERE HighImpact=\'1\' NOT WHERE HighImpact=1\n",
      "- CRITICAL: CADDphred, SIFT, PolyPhen missing values are '.' not NULL. Use != '.' not IS NOT NULL\n",
      "- For annotation distribution questions (PolyPhen, SIFT distribution):\n",
      "  use run_variant_query with GROUP BY, e.g.:\n",
      "  SELECT PolyPhen, COUNT(*) as n FROM varInfo_synthetic WHERE HighImpact=\'1\' GROUP BY PolyPhen\n",
      "- For chromosome with most variants: run_variant_query with GROUP BY CHROM ORDER BY COUNT(*) DESC LIMIT 1\n",
      "- For SIFT=\'T\' (tolerated) count across ALL genes: run_variant_query SELECT COUNT(*) FROM varInfo_synthetic WHERE SIFT=\'T\'\n",
      "- What percentage of variants carried by ALS: get_als_carrier_stats (server=variant_analysis, params={})\n",
      "- Which gene has most homozygous variant-calls across all ALS patients: run_variant_query\n",
      "  sql: SELECT gene_name,\n",
      "    SUM(CASE WHEN ALS_1=2 THEN 1 ELSE 0 END +\n",
      "        CASE WHEN ALS_2=2 THEN 1 ELSE 0 END +\n",
      "        CASE WHEN ALS_3=2 THEN 1 ELSE 0 END +\n",
      "        CASE WHEN ALS_4=2 THEN 1 ELSE 0 END +\n",
      "        CASE WHEN ALS_5=2 THEN 1 ELSE 0 END) AS total_hom\n",
      "  FROM varInfo_synthetic GROUP BY gene_name ORDER BY total_hom DESC LIMIT 5\n",
      "- CADD score bins with ALS burden: run_variant_query\n",
      "  sql: SELECT\n",
      "    CASE WHEN CAST(CADDphred AS REAL)<10 THEN \'<10\'\n",
      "         WHEN CAST(CADDphred AS REAL)<20 THEN \'10-20\'\n",
      "         WHEN CAST(CADDphred AS REAL)<30 THEN \'20-30\'\n",
      "         ELSE \'>=30\' END AS cadd_bin,\n",
      "    COUNT(*) AS n_variants,\n",
      "    SUM(ALS_1+ALS_2+ALS_3+ALS_4+ALS_5) AS als_burden\n",
      "  FROM varInfo_synthetic WHERE CADDphred!=\'.\' GROUP BY cadd_bin\n",
      "- Top 3 highest CADD variants across entire dataset: run_variant_query\n",
      "  sql: SELECT VAR_id, gene_name, CADDphred FROM varInfo_synthetic WHERE CADDphred != '.' ORDER BY CAST(CADDphred AS REAL) DESC LIMIT 3\n",
      "- 3 lowest non-zero AF variants: run_variant_query\n",
      "  sql: SELECT VAR_id, gene_name, AF FROM varInfo_synthetic WHERE AF != '.' AND CAST(AF AS REAL) > 0 ORDER BY CAST(AF AS REAL) ASC LIMIT 3\n",
      "- Variants shared by ALL 10 individuals: run_variant_query\n",
      "  sql: SELECT VAR_id, gene_name FROM varInfo_synthetic WHERE ALS_1>0 AND ALS_2>0 AND ALS_3>0 AND ALS_4>0 AND ALS_5>0 AND Control_1>0 AND Control_2>0 AND Control_3>0 AND Control_4>0 AND Control_5>0 LIMIT 200\n",
      "  This returns ROWS of variants \u2014 interpret the number of rows as the answer (expected: 29)\n",
      "- For PolyPhen=\'P\' (possibly damaging): run_variant_query\n",
      "  sql: SELECT COUNT(*) as n FROM varInfo_synthetic WHERE PolyPhen=\'P\'\n",
      "  PolyPhen codes: D=damaging, P=possibly_damaging, B=benign, .=missing \u2014 single letter only\n",
      "- count_sift_deleterious_in_gene and count_variants_in_gene ALWAYS need a specific gene name \u2014 never call without gene\n",
      "- impact param: ONLY set impact if the user explicitly mentions 'high impact', 'moderate impact', etc. If no impact is mentioned, omit impact or use impact='any'.\n",
      "- get_carriers_with_phenotype: server=phenotype_data (NOT genotype_analysis)\n",
      "  ALWAYS call as phenotype_data/get_carriers_with_phenotype\n",
      "- get_carriers_with_phenotype returns ALL matching carriers in one call. If it returns a list of carriers, that IS the complete answer \u2014 output status=final immediately. Do NOT call it again with different population filters.\n",
      "- If a tool returns 'No qualifying carriers found', that IS the final answer \u2014 output status=final immediately.\n",
      "- NEVER use run_phenotype_query to answer carrier questions. run_phenotype_query does not have access to genotype columns.\n",
      "- Do NOT add a population filter unless the user explicitly names a population.\n",
      if (!is.na(entities$gene))       paste0("- Target gene for this question: ", entities$gene, "\n") else "",
      if (!is.na(entities$sex))        paste0("- Target sex for this question: sex=", as.integer(entities$sex),
                                              " (integer, NOT string \u2014 1=female, 2=male)\n") else "",
      if (!is.na(entities$population)) paste0("- Target population superPop code: '", entities$population,
                                              "' (e.g. SAS=South Asian, EUR=European, AFR=African)\n") else "",
      "- Output JSON: {\"status\": \"continue\", \"server\": \"...\", \"tool\": \"...\", \"params\": {...}}\n",
      "- OR: {\"status\": \"final\"} if done\n"
    )
    
    step_prompt <- paste0(
      "Original question: ", question, "\n",
      if (nchar(context) > 0) paste0("Context so far:\n", context, "\n") else "",
      "What tool should I call next? Output ONLY JSON."
    )
    
    cat("[AGENTIC] Step", step, "— querying LLM\n")
    raw_decision <- call_ollama(step_prompt, system_prompt = step_sys,
                                model = orch_model, json_mode = TRUE,
                                num_predict = 200)
    cat("[AGENTIC] Step", step, "— LLM raw decision:", raw_decision, "\n")
    decision <- parse_json_response(raw_decision)
    
    ## Check if done
    if (is.null(decision) ||
        (!is.null(decision$status) && decision$status == "final")) {
      cat("[AGENTIC] Step", step, "— status=final, stopping\n")
      break
    }
    
    ## Parse server/tool — handle combined or split formats
    tool_raw   <- decision$tool %||% ""
    server_raw <- decision$server %||% ""
    if (grepl("/", tool_raw)) {
      parts  <- strsplit(tool_raw, "/")[[1]]
      server <- parts[1]; tool <- paste(parts[-1], collapse = "/")
    } else if (grepl("/", server_raw)) {
      parts  <- strsplit(server_raw, "/")[[1]]
      server <- tail(parts, 1); tool <- tool_raw
    } else {
      server <- if (nchar(server_raw) > 0) server_raw else "variant_analysis"
      tool   <- tool_raw
    }
    params <- if (is.null(decision$params)) list() else as.list(decision$params)
    params <- params[!sapply(params, function(v) is.null(v) || identical(v, ""))]
    
    if (is.null(tool) || nchar(tool) == 0) {
      cat("[AGENTIC] Step", step, "— empty tool, breaking\n")
      break
    }
    
    step_label <- paste0(server, "/", tool)
    cat("[AGENTIC] Step", step, "— calling:", step_label,
        "| params:", paste(names(params), unlist(params), sep = "=", collapse = ", "), "\n")
    
    raw_result <- call_mcp(server, tool, params)
    mcp_err    <- check_mcp_error(raw_result)
    steps_log  <- c(steps_log, step_label)
    
    if (!is.null(mcp_err)) {
      cat("[AGENTIC] Step", step, "— MCP error:", mcp_err, "\n")
      context <- paste0(context, "\nStep ", step, " (", step_label, "): ERROR — ", mcp_err, "\n")
      break
    }
    
    result_len <- nchar(raw_result)
    cat("[AGENTIC] Step", step, "— result length:", result_len, "chars |",
        substr(raw_result, 1, 150), "\n")
    
    ## Early exit: same result as last step — LLM is stuck
    if (step > 1 && raw_result == last_result && nchar(raw_result) > 0) {
      cat("[AGENTIC] Step", step, "— same result as previous step, stopping\n")
      break
    }
    
    ## Early exit: get_maf_by_impact SUMMARY row is the complete answer
    is_maf_tool <- grepl("get_maf_by_impact", step_label, fixed = TRUE)
    has_summary  <- grepl("SUMMARY", raw_result, fixed = TRUE)
    if (is_maf_tool && has_summary) {
      cat("[AGENTIC] Step", step, "— MAF summary received, stopping early\n")
      best_result <- raw_result
      break
    }
    
    ## Early exit: get_carriers_with_phenotype is exhaustive — one call is enough
    is_carrier_tool <- grepl("get_carriers_with_phenotype", step_label, fixed = TRUE)
    has_carriers    <- is_carrier_tool && grepl("\"IID\"", raw_result, fixed = TRUE)
    is_null_result  <- grepl("No qualifying", raw_result, fixed = TRUE)
    
    if (is_carrier_tool && (has_carriers || is_null_result)) {
      best_result <- raw_result
      best_df     <- result_to_df(raw_result)
      best_params <- params
      cat("[AGENTIC] Step", step, "— carrier tool complete, stopping early\n")
      context     <- paste0(context, "\nStep ", step, " (", step_label, "):\n", raw_result, "\n")
      last_result <- raw_result
      last_df     <- result_to_df(raw_result)
      break
    }
    
    ## Prefer shorter targeted results over large noisy tables
    if (result_len > 0 && (result_len < 3000 || nchar(best_result) == 0)) {
      best_result <- raw_result
      best_df     <- result_to_df(raw_result)
      best_params <- params
    }
    
    result_preview <- if (result_len > 600) {
      paste0(substr(raw_result, 1, 600), "... [truncated, ", result_len, " total chars]")
    } else raw_result
    
    context     <- paste0(context, "\nStep ", step, " (", step_label, "):\n", result_preview, "\n")
    last_result <- raw_result
    last_df     <- result_to_df(raw_result)
  }  ## end for loop
  
  cat("[AGENTIC] Done —", length(steps_log), "steps:", paste(steps_log, collapse = " \u2192 "), "\n")
  cat("[AGENTIC] best_result length:", nchar(best_result),
      "| last_result length:", nchar(last_result), "\n")
  
  if (!is.null(progress_fn)) progress_fn("Formulating answer...", MAX_STEPS + 1)
  
  final_result <- if (nchar(best_result) > 0) best_result else context
  final_df     <- if (!is.null(best_df)) best_df else last_df
  summary_text <- summarize_result(question, steps_log, final_result,
                                   if (!is.null(final_df)) nrow(final_df) else NULL,
                                   orch_model = orch_model)
  list(
    ok        = TRUE,
    text      = summary_text,
    tool      = paste(steps_log, collapse = " \u2192 "),
    params    = best_params,
    df        = last_df,
    mode      = "agentic",
    steps     = length(steps_log),
    steps_log = steps_log
  )
}  ## end run_agentic_pipeline

# ══════════════════════════════════════════════════════════════════════════════
# SIMPLE PIPELINES
# ══════════════════════════════════════════════════════════════════════════════

run_single_pipeline <- function(question, model, progress_fn = NULL) {
  if (!is.null(progress_fn)) progress_fn("LLM interpreting and classifying...", 1)
  
  cl <- classify_tool(question, orch_model = model)
  if (!cl$ok) {
    cl <- classify_tool(paste0(question, "\nRespond with ONLY a JSON object."),
                        orch_model = model)
  }
  if (!cl$ok) return(list(ok = FALSE, text = paste("Classification failed:", cl$error),
                          tool = NULL, df = NULL))
  
  server <- cl$server
  tool   <- cl$tool
  params <- cl$params
  
  cat("[SIMPLE] Question:", question, "\n")
  cat("[SIMPLE] Server:", server, "| Tool:", tool, "\n")
  cat("[SIMPLE] Params:", paste(names(params), unlist(params), sep = "=", collapse = ", "), "\n")
  
  if (!is.null(progress_fn)) progress_fn("Executing query via MCP...", 2)
  raw_result <- call_mcp(server, tool, params)
  cat("[SIMPLE] Result:", substr(raw_result, 1, 200), "\n")
  
  mcp_err <- check_mcp_error(raw_result)
  if (!is.null(mcp_err)) return(list(ok = FALSE, text = paste("Database error:", mcp_err),
                                     tool = tool, df = NULL))
  
  if (!is.null(progress_fn)) progress_fn("Formulating answer...", 3)
  df <- result_to_df(raw_result)
  summary_text <- summarize_result(question, paste0(server, "/", tool), raw_result,
                                   nrow(df), orch_model = model)
  list(ok = TRUE, text = summary_text, tool = paste0(server, "/", tool),
       df = df, mode = "single", params = params)
}

run_dual_pipeline <- function(question, orch_model, sub_model,
                              sub_sql = NULL, sub_reason = NULL,
                              progress_fn = NULL) {
  if (!is.null(progress_fn)) progress_fn("Orchestrator interpreting question...", 1)
  
  cl <- classify_tool(question, orch_model = orch_model)
  if (!cl$ok) {
    cl <- classify_tool(paste0(question, "\nRespond with ONLY a JSON object."),
                        orch_model = orch_model)
  }
  if (!cl$ok) return(list(ok = FALSE, text = paste("Classification failed:", cl$error),
                          tool = NULL, df = NULL))
  
  server <- cl$server
  tool   <- cl$tool
  params <- cl$params
  
  cat("[DUAL] Question:", question, "\n")
  cat("[DUAL] Server:", server, "| Tool:", tool, "\n")
  cat("[DUAL] Params:", paste(names(params), unlist(params), sep = "=", collapse = ", "), "\n")
  
  ## Adaptive LLM2 routing:
  ## - run_variant_query → use sub_sql (duckdb-nsql) if available, else check sub_model
  ## - named tools / agentic → use sub_reason (llama3.1) if available, else sub_model
  active_sql_model <- sub_sql %||% sub_model
  is_sql_specialist <- !is.null(active_sql_model) &&
    grepl("duckdb|sql|sqlcoder", active_sql_model, ignore.case = TRUE)
  
  if (tool == "run_variant_query" && !is.null(params$sql) && is_sql_specialist) {
    if (!is.null(progress_fn)) progress_fn(paste0("SQL specialist (", active_sql_model, ") refining query..."), 2)
    sub_model <- active_sql_model  ## use SQL specialist for this call
    sub_sys <- paste0(
      "You are a SQLite SQL specialist. The database is SQLite — NOT DuckDB, NOT PostgreSQL.\n",
      "CRITICAL: Never use DuckDB syntax. Forbidden: ::REAL, ::INTEGER, QUALIFY, EXCLUDE, PIVOT.\n",
      "For type casting ALWAYS use SQLite syntax: CAST(col AS REAL), CAST(col AS INTEGER).\n",
      "For casting: CAST(CADDphred AS REAL) is correct. CADDphred::REAL is WRONG.\n",
      "Improve the following SQL query for the varInfo_synthetic table.\n",
      "SCHEMA: gene_name, VAR_id, CHROM, POS, REF, ALT, AF (TEXT), HighImpact (TEXT \'0\'\'/\'1\'),\n",
      "  ModerateImpact (TEXT), Synonymous (TEXT), CADDphred (TEXT, \'.\'=missing),\n",
      "  SIFT (TEXT: D/T/.), PolyPhen (TEXT: D/P/B/.), ALS_1..ALS_5 (INTEGER), Control_1..Control_5 (INTEGER)\n",
      "RULES:\n",
      "- NEVER use IS NULL or IS NOT NULL — missing values are \'.\', use != \'.\' instead\n",
      "- ALWAYS use CAST(CADDphred AS REAL) and CAST(AF AS REAL) for numeric comparisons\n",
      "- HighImpact/ModerateImpact/Synonymous are TEXT \'0\'/\'1\', not integers\n",
      "- ALS_1..ALS_5 are genotype columns (0=ref, 1=het, 2=hom), NOT gene names\n",
      "- CHROM values include chr prefix: \'chrX\' not \'X\'\n",
      "- All SELECT parts in a UNION must have the same number of columns\n",
      "Return ONLY the corrected SQL. No explanation. No markdown."
    )
    improved_sql <- call_ollama(
      paste0("Improve this SQL:\n", params$sql),
      system_prompt = sub_sys,
      model = sub_model,
      num_predict = 400
    )
    improved_sql <- trimws(gsub("```sql|```", "", improved_sql))
    if (grepl("^SELECT", improved_sql, ignore.case = TRUE) &&
        !grepl("::", improved_sql, fixed = TRUE)) {  ## reject DuckDB cast syntax
      cat("[DUAL] SQL refined by", sub_model, ":\n", improved_sql, "\n")
      params_backup <- params
      params$sql <- improved_sql
      ## Validate: test the refined SQL before committing
      test_result <- tryCatch(call_mcp(server, tool, params), error = function(e) NULL)
      if (!is.null(test_result) && grepl("error.*500|HTTP 500", test_result, ignore.case=TRUE)) {
        cat("[DUAL] Refined SQL failed, reverting to original\n")
        params <- params_backup
      }
    } else {
      cat("[DUAL] SQL refinement rejected (DuckDB syntax or invalid), using original\n")
    }
  }
  
  if (!is.null(progress_fn)) progress_fn("Executing query via MCP...", 3)
  raw_result <- call_mcp(server, tool, params)
  cat("[DUAL] Result:", substr(raw_result, 1, 200), "\n")
  
  mcp_err <- check_mcp_error(raw_result)
  if (!is.null(mcp_err)) return(list(ok = FALSE, text = paste("Database error:", mcp_err),
                                     tool = tool, df = NULL))
  
  if (!is.null(progress_fn)) progress_fn("Formulating answer...", 4)
  df <- result_to_df(raw_result)
  summary_text <- summarize_result(question, paste0(server, "/", tool), raw_result,
                                   nrow(df), orch_model = orch_model)
  list(ok = TRUE, text = summary_text, tool = paste0(server, "/", tool),
       df = df, mode = "dual", params = params)
}

## ── Master dispatcher ─────────────────────────────────────────────────────
run_pipeline <- function(question, p, progress_fn = NULL) {
  if (is_unanswerable(question)) {
    if (!is.null(progress_fn)) progress_fn("Checking database limitations...", 0)
    raw_result   <- call_mcp("db_exploration", "get_database_limitations", list())
    df           <- result_to_df(raw_result)
    summary_text <- summarize_result(question, "db_exploration/get_database_limitations",
                                     raw_result, NULL, orch_model = p$orch)
    return(list(ok = TRUE, text = summary_text,
                tool = "db_exploration/get_database_limitations",
                params = list(), df = df, mode = "simple", steps = 1,
                complexity = "unanswerable_precheck"))
  }
  
  if (!is.null(progress_fn)) progress_fn("Classifying question complexity...", 0)
  complexity <- classify_complexity(question)
  
  if (complexity == "complex") {
    if (!is.null(progress_fn)) progress_fn("Complex question — starting agentic loop...", 1)
    result <- run_agentic_pipeline(question, orch_model = p$orch, progress_fn = progress_fn)
  } else {
    if (p$mode %in% c("dual", "dual_adaptive")) {
      result <- run_dual_pipeline(
        question,
        orch_model = p$orch,
        sub_model  = p$sub %||% p$sub_reason %||% p$orch,
        sub_sql    = p$sub_sql %||% NULL,
        sub_reason = p$sub_reason %||% NULL,
        progress_fn = progress_fn
      )
    } else {
      result <- run_single_pipeline(question, p$orch, progress_fn)
    }
  }
  result$complexity <- complexity
  result
}

# ══════════════════════════════════════════════════════════════════════════════
# UI
# ══════════════════════════════════════════════════════════════════════════════

ui <- page_sidebar(
  title = "Project ALS \u2014 Variant Assistant v2 (Agentic)",
  theme = bs_theme(
    version    = 5,
    bootswatch = "flatly",
    primary    = "#2A9D8F",
    secondary  = "#457B9D",
    "navbar-bg" = "#18bc9c"
  ),
  
  useShinyjs(),
  tags$head(
    tags$style(HTML("
      .chat-bubble-user {
        background: #2A9D8F; color: white;
        padding: 10px 14px; border-radius: 18px 18px 4px 18px;
        margin: 6px 0 6px 50px; text-align: right;
      }
      .chat-bubble-bot {
        background: white; border: 1px solid #dee2e6;
        padding: 10px 14px; border-radius: 18px 18px 18px 4px;
        margin: 6px 50px 6px 0;
      }
      .tool-badge { color: #666; font-size: 0.8em; display: block; margin-bottom: 4px; }
      .progress-step { color: #2A9D8F; font-size: 0.85em; margin: 2px 0; }
      .progress-step.done { color: #aaa; }
      #chat_scroll { height: 520px; overflow-y: auto; padding: 12px;
                     background: #f8f9fa; border: 1px solid #dee2e6;
                     border-radius: 6px; }
      .mode-badge { font-size: 0.75em; padding: 2px 8px; border-radius: 12px;
                    font-weight: 600; }
      .mode-single { background: #e8f4f1; color: #2A9D8F; }
      .mode-dual   { background: #e8eef4; color: #457B9D; }
      .shiny-progress .progress-bar { background-color: #2A9D8F !important; }
      .shiny-progress .progress { background-color: #e8f4f1 !important; }
      .shiny-progress-container { top: 60px !important; }
      .progress-bar { background-color: #2A9D8F !important; }
      .shiny-progress-indicator { background-color: #2A9D8F !important; }
      #shiny-notification-panel .progress-bar { background-color: #2A9D8F !important; }
      .navbar, .navbar-default, nav.navbar { background-color: #18bc9c !important; border-color: #18bc9c !important; }
      .bslib-page-sidebar > .navbar { background-color: #18bc9c !important; }
      #send_btn { background-color: #2A9D8F !important; border-color: #2A9D8F !important; color: white !important; }
      #send_btn:hover { background-color: #21867a !important; border-color: #21867a !important; }
      .input-disabled { opacity: 0.5; pointer-events: none; }
      .sidebar a { color: #2A9D8F !important; }
      .chat-bubble-unanswerable {
        background: #f8f9fa; border: 1px dashed #ced4da;
        padding: 10px 14px; border-radius: 18px 18px 18px 4px;
        margin: 6px 50px 6px 0; color: #6c757d;
      }
      .tool-detail {
        margin-top: 8px; padding: 8px 10px;
        background: #f8f9fa; border-radius: 6px;
        border-left: 3px solid #dee2e6;
        font-size: 0.8em; color: #555;
      }
      .tool-detail > summary {
        cursor: pointer; color: #888; font-size: 0.82em;
        user-select: none; list-style: none; outline: none;
      }
      .tool-detail > summary::-webkit-details-marker { display: none; }
      .tool-detail > summary::before { content: '\25B6  '; font-size: 0.75em; }
      .tool-detail[open] > summary::before { content: '\25BC  '; }
      .sql-block {
        margin-top: 6px; padding: 6px 8px;
        background: #1e1e2e; color: #cdd6f4;
        border-radius: 4px; font-family: monospace;
        font-size: 0.82em; white-space: pre-wrap; word-break: break-all;
      }
      .conf-high   { background:#ffeaea; color:#c0392b; border:1px solid #f5c6cb;
                     font-size:0.72em; padding:1px 7px; border-radius:10px; font-weight:600; }
      .conf-medium { background:#fff8e1; color:#856404; border:1px solid #ffeeba;
                     font-size:0.72em; padding:1px 7px; border-radius:10px; font-weight:600; }
      .conf-low    { background:#e8f4f1; color:#2A9D8F; border:1px solid #c3e6e0;
                     font-size:0.72em; padding:1px 7px; border-radius:10px; font-weight:600; }
      .tracker-row {
        display: flex; justify-content: space-between; align-items: center;
        padding: 5px 10px; border-radius: 6px; margin-bottom: 4px;
        border-left: 3px solid #2A9D8F; background: #f0f9f8;
      }
      .tracker-row.error-row { border-left-color: #E63946; background: #fef0f1; }
      .tracker-label { font-size: 0.78em; color: #666; }
      .tracker-value { font-size: 0.9em; font-weight: 600; color: #2A9D8F; }
      .tracker-value.error-value { color: #E63946; }
      .model-option {
        display: flex; align-items: flex-start; gap: 8px;
        padding: 8px 10px; border-radius: 8px; margin-bottom: 6px;
        border: 1px solid #dee2e6; cursor: pointer;
        transition: border-color 0.15s, background 0.15s;
        background: white;
      }
      .model-option:hover { border-color: #2A9D8F; background: #f0f9f8; }
      .model-option.selected { border-color: #2A9D8F; background: #f0f9f8; }
      .model-option input[type=radio] { margin-top: 3px; accent-color: #2A9D8F; flex-shrink: 0; }
      .model-option-body { display: flex; flex-direction: column; gap: 2px; }
      .model-option-label { font-size: 0.82em; font-weight: 600; color: #333; line-height: 1.3; }
      .model-option-desc  { font-size: 0.74em; color: #888; line-height: 1.3; }
      .model-mode-pill {
        display: inline-block; font-size: 0.68em; font-weight: 600;
        padding: 1px 6px; border-radius: 8px; margin-left: 4px;
        vertical-align: middle;
      }
      .pill-single { background: #e8f4f1; color: #2A9D8F; }
      .pill-dual   { background: #e8eef4; color: #457B9D; }
      .qhist-item {
        display: flex; align-items: center; gap: 6px;
        padding: 5px 8px; border-radius: 6px; margin-bottom: 3px;
        background: #f8f9fa; border: 1px solid #eee;
        cursor: pointer; transition: background 0.12s, border-color 0.12s;
      }
      .qhist-item:hover { background: #e8f4f1; border-color: #2A9D8F; }
      .qhist-num {
        font-size: 0.68em; font-weight: 700; color: #aaa;
        min-width: 16px; text-align: right; flex-shrink: 0;
      }
      .qhist-text {
        font-size: 0.76em; color: #444; white-space: nowrap;
        overflow: hidden; text-overflow: ellipsis; flex: 1;
      }
      .qhist-empty {
        font-size: 0.78em; color: #aaa; font-style: italic;
        padding: 4px 8px;
      }
      #export_btn {
        width: 100%;
        background: white !important;
        border: 1px solid #2A9D8F !important;
        color: #2A9D8F !important;
        font-size: 0.82em;
        padding: 4px 10px;
        border-radius: 6px;
      }
      #export_btn:hover { background: #e8f4f1 !important; }
      .export-option {
        display: flex; align-items: flex-start; gap: 8px;
        padding: 8px 10px; border-radius: 8px; margin-bottom: 6px;
        border: 1px solid #dee2e6; cursor: pointer;
        transition: border-color 0.15s, background 0.15s;
        background: white;
      }
      .export-option:hover { border-color: #2A9D8F; background: #f0f9f8; }
      @keyframes mine-bounce {
        0%, 100% { transform: scale(1);   opacity: 1; }
        50%       { transform: scale(0.4); opacity: 0.4; }
      }
      .export-section-label {
        font-size: 0.78em; font-weight: 700; color: #888;
        text-transform: uppercase; letter-spacing: 0.04em;
        margin: 10px 0 5px 0;
      }
      .sb-section {
        border: 1px solid #e4eeec; border-radius: 8px;
        margin-bottom: 6px; overflow: hidden;
      }
      .sb-section > summary {
        display: flex; align-items: center; justify-content: space-between;
        padding: 7px 11px; cursor: pointer;
        font-size: 0.82em; font-weight: 700; color: #444;
        background: #f0f9f8; user-select: none;
        list-style: none; outline: none;
        border-radius: 8px; transition: background 0.12s;
      }
      .sb-section > summary::-webkit-details-marker { display: none; }
      .sb-section > summary::after {
        content: '';
        display: inline-block;
        width: 0; height: 0;
        border-top: 5px solid transparent;
        border-bottom: 5px solid transparent;
        border-left: 6px solid #2A9D8F;
        transition: transform 0.15s;
        flex-shrink: 0;
      }
      .sb-section[open] > summary { border-radius: 8px 8px 0 0; background: #e4f5f2; }
      .sb-section[open] > summary::after { transform: rotate(90deg); }
      .sb-section > summary:hover { background: #e4f5f2; }
      .sb-section-body { padding: 10px 11px 10px 11px; }
    ")),
    tags$script(HTML(
      "$(document).on('keypress', '#user_input', function(e) {
         if (e.which == 13 && !e.shiftKey) { e.preventDefault(); $('#send_btn').click(); }
       });
       function selectModel(key) {
         document.querySelectorAll('.model-option').forEach(function(el) {
           el.classList.remove('selected');
         });
         var opt = document.getElementById('model-opt-' + key);
         if (opt) opt.classList.add('selected');
         Shiny.setInputValue('selected_model', key, {priority: 'event'});
       }
       function historyClick(q) {
         var el = document.getElementById('user_input');
         if (el) {
           el.value = q;
           el.dispatchEvent(new Event('input'));
         }
       }"
    ))
  ),
  
  sidebar = sidebar(
    width = 310,
    div(style = "margin-bottom:10px;",
        h4("Variant Assistant", style = "margin:0 0 2px 0;"),
        p("ALS variant database assistant.", style = "color:#888; font-size:0.8em; margin:0;")),
    
    tags$details(
      class = "sb-section", open = NA,
      tags$summary("Pipeline"),
      div(class = "sb-section-body", uiOutput("model_switcher_ui"))
    ),
    
    tags$details(
      class = "sb-section",
      tags$summary("Example Questions"),
      div(class = "sb-section-body",
          tags$ul(
            style = "padding-left:14px; margin:0;",
            tags$li(actionLink("ex1", "How many variants are in ABCA4?")),
            tags$li(actionLink("ex2", "How many variants in SOD1 are high impact?")),
            tags$li(actionLink("ex3", "How many genes are in the database?")),
            tags$li(actionLink("ex4", "How many total variants are in the database?")),
            tags$li(actionLink("ex5", "How many variants have PolyPhen predicted damaging?")),
            tags$li(actionLink("ex6", "Which gene has the fewest variants?")),
            tags$li(actionLink("ex7", "How many high-impact variants does ALS_3 carry?")),
            tags$li(actionLink("ex8", "What is the average age of ALS patients?"))
          ))
    ),
    
    tags$details(
      class = "sb-section",
      tags$summary("Question History"),
      div(class = "sb-section-body", uiOutput("question_history_ui"))
    ),
    
    tags$details(
      class = "sb-section", open = NA,
      tags$summary("Status"),
      div(class = "sb-section-body", uiOutput("status_ui"))
    ),
    
    tags$details(
      class = "sb-section", open = NA,
      tags$summary("Session"),
      div(class = "sb-section-body", uiOutput("session_tracker_ui"))
    ),
    
    div(style = "margin-top:8px;",
        actionButton("export_btn", "Export session", class = "btn btn-sm",
                     style = "width:100%;"))
  ),
  
  layout_columns(
    col_widths = c(5, 7),
    card(
      full_screen = TRUE,
      card_header(
        div(style = "display:flex; justify-content:space-between; align-items:center;",
            h4("Chat", style = "margin:0;"),
            div(style = "display:flex; align-items:center; gap:8px;",
                uiOutput("mode_badge_ui"),
                actionButton("clear_btn_header", "\u2715",
                             title = "Clear conversation",
                             class = "btn btn-sm",
                             style = "padding:1px 7px; font-size:0.8em; line-height:1.4;
                                      background:transparent; border:1px solid #dee2e6;
                                      color:#999; border-radius:12px;")))
      ),
      div(id = "chat_scroll", uiOutput("chat_ui")),
      uiOutput("progress_ui"),
      uiOutput("input_area_ui")
    ),
    card(
      full_screen = TRUE,
      card_header(
        div(style = "display:flex; justify-content:space-between; align-items:center;",
            uiOutput("results_title_ui"),
            uiOutput("row_count_ui"))
      ),
      DTOutput("result_table")
    )
  )
)

# ══════════════════════════════════════════════════════════════════════════════
# SERVER
# ══════════════════════════════════════════════════════════════════════════════

server <- function(input, output, session) {
  
  rv <- reactiveValues(
    messages            = list(),
    last_df             = NULL,
    is_loading          = FALSE,
    mcp_ok              = NA,
    row_count           = NULL,
    progress_log        = character(0),
    questions_asked     = 0L,
    tools_called        = 0L,
    errors_this_session = 0L,
    question_history    = character(0)
  )
  
  observe({
    tryCatch({
      resp <- request(MCP_BASE) |> req_url_path("/openapi.json") |> req_timeout(4) |> req_perform()
      rv$mcp_ok <- resp_status(resp) == 200
    }, error = function(e) rv$mcp_ok <- FALSE)
  })
  
  current_pipeline <- reactive({
    key <- if (is.null(input$selected_model)) "dual_llama" else input$selected_model
    AVAILABLE_MODELS[[key]]
  })
  
  output$model_switcher_ui <- renderUI({
    selected <- if (is.null(input$selected_model)) "dual_llama" else input$selected_model
    opts <- lapply(names(AVAILABLE_MODELS), function(key) {
      m <- AVAILABLE_MODELS[[key]]
      pill_class <- if (m$mode %in% c("dual", "dual_adaptive")) "model-mode-pill pill-dual" else "model-mode-pill pill-single"
      pill_text  <- if (m$mode == "dual_adaptive") "adaptive" else if (m$mode == "dual") "two LLM" else "single"
      is_sel <- identical(key, selected)
      div(
        id    = paste0("model-opt-", key),
        class = if (is_sel) "model-option selected" else "model-option",
        onclick = paste0("selectModel('", key, "')"),
        tags$input(type = "radio", name = "model_radio", value = key,
                   checked = if (is_sel) NA else NULL),
        div(class = "model-option-body",
            div(class = "model-option-label",
                m$label,
                span(class = pill_class, pill_text)),
            div(class = "model-option-desc", m$desc))
      )
    })
    tagList(opts)
  })
  
  output$mode_badge_ui <- renderUI({
    p <- current_pipeline()
    tags$div(
      if (p$mode == "dual") span("Two LLM", class = "mode-badge mode-dual")
      else                  span("Single LLM", class = "mode-badge mode-single"),
      span("+ Agentic", class = "mode-badge",
           style = "background:#fff3cd; color:#856404; margin-left:4px;")
    )
  })
  
  output$status_ui <- renderUI({
    if (is.na(rv$mcp_ok)) {
      div(style = "color:#888;", "\u25cf Checking...")
    } else if (rv$mcp_ok) {
      div(style = "color:#2A9D8F; font-weight:bold;", "\u25cf MCP connected")
    } else {
      tagList(div(style = "color:red; font-weight:bold;", "\u25cf MCP unreachable"),
              tags$small("Restart start_services.sh"))
    }
  })
  
  output$session_tracker_ui <- renderUI({
    has_errors <- rv$errors_this_session > 0L
    div(
      div(class = "tracker-row",
          span(class = "tracker-label", "Questions asked"),
          span(class = "tracker-value", rv$questions_asked)),
      div(class = "tracker-row",
          span(class = "tracker-label", "Tools called"),
          span(class = "tracker-value", rv$tools_called)),
      div(class = if (has_errors) "tracker-row error-row" else "tracker-row",
          span(class = "tracker-label", "Errors"),
          span(class = if (has_errors) "tracker-value error-value" else "tracker-value",
               rv$errors_this_session))
    )
  })
  
  output$question_history_ui <- renderUI({
    qs <- rv$question_history
    if (length(qs) == 0) {
      return(div(class = "qhist-empty", "No questions yet."))
    }
    items <- lapply(rev(seq_along(qs)), function(i) {
      q     <- qs[[i]]
      label <- if (nchar(q) > 48) paste0(substr(q, 1, 45), "\u2026") else q
      div(
        class   = "qhist-item",
        title   = q,
        onclick = paste0("historyClick(", jsonlite::toJSON(q, auto_unbox = TRUE), ")"),
        span(class = "qhist-num",  paste0("#", i)),
        span(class = "qhist-text", label)
      )
    })
    div(style = "max-height:180px; overflow-y:auto;", items)
  })
  
  output$row_count_ui <- renderUI({
    req(!is.null(rv$row_count))
    tags$small(style = "color:#666;", paste0(rv$row_count, " rows"))
  })
  
  output$results_title_ui <- renderUI({
    if (rv$is_loading) {
      div(style = "display:flex; align-items:center; gap:8px;",
          h4("Results", style = "margin:0;"),
          tags$span(style = "font-size:0.78em; color:#2A9D8F; font-weight:600;
                             background:#e8f4f1; padding:2px 8px; border-radius:10px;",
                    "\u27f3 Waiting for query..."))
    } else if (!is.null(rv$last_df)) {
      h4("Results", style = "margin:0;")
    } else {
      div(style = "display:flex; align-items:center; gap:8px;",
          h4("Results", style = "margin:0;"),
          tags$span(style = "font-size:0.78em; color:#aaa; padding:2px 4px;",
                    "Ask a question to see data"))
    }
  })
  
  observeEvent(input$clear_btn_header, {
    rv$messages             <- list()
    rv$last_df              <- NULL
    rv$row_count            <- NULL
    rv$progress_log         <- character(0)
    rv$questions_asked      <- 0L
    rv$tools_called         <- 0L
    rv$errors_this_session  <- 0L
    rv$question_history     <- character(0)
  })
  
  output$progress_ui <- renderUI({
    if (!rv$is_loading && length(rv$progress_log) == 0) return(NULL)
    steps <- rv$progress_log
    els <- lapply(seq_along(steps), function(i) {
      is_last <- i == length(steps)
      icon <- if (!is_last || !rv$is_loading) "\u2713" else "\u27f3"
      cls  <- if (!is_last || !rv$is_loading) "progress-step done" else "progress-step"
      div(class = cls, paste(icon, steps[i]))
    })
    div(style = "margin-top:6px; padding:8px 12px; background:#f0f9f8;
                 border-radius:6px; border-left:4px solid #2A9D8F;", els)
  })
  
  ex_map <- list(
    ex1 = "How many variants are in ABCA4?",
    ex2 = "How many variants in SOD1 are high impact?",
    ex3 = "How many genes are in the database?",
    ex4 = "How many total variants are in the database?",
    ex5 = "How many variants have PolyPhen predicted damaging?",
    ex6 = "Which gene has the fewest variants?",
    ex7 = "How many high-impact variants does ALS_3 carry?",
    ex8 = "What is the average age of ALS patients?"
  )
  for (id in names(ex_map)) {
    local({
      q <- ex_map[[id]]
      observeEvent(input[[id]], updateTextInput(session, "user_input", value = q))
    })
  }
  
  output$input_area_ui <- renderUI({
    div(style = "display:flex; gap:8px; margin-top:10px;",
        textInput("user_input", label = NULL, width = "100%",
                  placeholder = "Ask a question... (Enter to send)"),
        actionButton("send_btn", "\u2192", class = "btn-primary"))
  })
  
  observe({
    if (rv$is_loading) {
      shinyjs::disable("user_input")
      shinyjs::disable("send_btn")
      shinyjs::addCssClass("user_input", "input-disabled")
    } else {
      shinyjs::enable("user_input")
      shinyjs::enable("send_btn")
      shinyjs::removeCssClass("user_input", "input-disabled")
    }
  })
  
  handle_send <- function() {
    question <- trimws(input$user_input)
    req(nchar(question) > 0, !rv$is_loading)
    updateTextInput(session, "user_input", value = "")
    
    prev <- rv$question_history
    if (length(prev) == 0 || tail(prev, 1) != question) {
      rv$question_history <- c(prev, question)
    }
    
    rv$messages     <- c(rv$messages, list(list(role = "user", text = question)))
    rv$is_loading   <- TRUE
    rv$row_count    <- NULL
    rv$progress_log <- character(0)
    shinyjs::delay(100, {
      p <- isolate(current_pipeline())
      total_steps <- 6
      result <- withProgress(message = "Processing your question...", value = 0, {
        update_progress <- function(msg, step) {
          rv$progress_log <- c(rv$progress_log, msg)
          setProgress(value = step / total_steps, message = msg)
        }
        tryCatch({
          run_pipeline(question, p, update_progress)
        }, error = function(e) list(ok = FALSE, text = paste("Error:", e$message), tool = NULL, df = NULL))
      })
      
      rv$questions_asked <- rv$questions_asked + 1L
      
      if (result$ok) {
        rv$last_df      <- result$df
        rv$row_count    <- if (!is.null(result$df)) nrow(result$df) else NULL
        rv$tools_called <- rv$tools_called + 1L
      } else {
        rv$errors_this_session <- rv$errors_this_session + 1L
      }
      
      rv$messages <- c(rv$messages, list(list(
        role = "assistant", text = result$text, tool = result$tool,
        params = result$params, mode = p$mode
      )))
      rv$is_loading <- FALSE
    })
  }
  
  observeEvent(input$send_btn, handle_send())
  
  output$chat_ui <- renderUI({
    msgs <- rv$messages
    if (length(msgs) == 0) {
      return(p(style = "color:#999; font-style:italic; text-align:center; margin-top:40px;",
               "Ask a question about the ALS variant database..."))
    }
    
    tool_confidence <- function(tool) {
      if (is.null(tool)) return(NULL)
      if (tool == "run_query")
        return(tags$span(class = "conf-high", "\u26a0 free SQL \u2014 verify"))
      if (tool == "get_database_limitations")
        return(tags$span(class = "conf-medium", "\u2718 unanswerable"))
      return(tags$span(class = "conf-low", "\u2714 named tool"))
    }
    
    tool_detail_panel <- function(tool, params) {
      if (is.null(tool)) return(NULL)
      param_lines <- if (!is.null(params) && length(params) > 0) {
        paste(names(params), unlist(params), sep = " = ", collapse = "\n")
      } else "(no params)"
      sql_block <- if (!is.null(params$sql)) {
        div(class = "sql-block", params$sql)
      } else NULL
      tags$details(
        class = "tool-detail",
        tags$summary("tool details"),
        div(style = "margin-top:5px;",
            tags$b("Tool: "), tags$code(tool), tags$br(),
            if (!is.null(params$sql)) NULL else
              tagList(tags$b("Params: "),
                      tags$code(style = "font-size:0.9em;", param_lines)),
            sql_block)
      )
    }
    
    els <- lapply(msgs, function(m) {
      if (m$role == "user") {
        div(class = "chat-bubble-user", m$text)
      } else {
        is_unanswerable_msg <- identical(m$tool, "get_database_limitations")
        bubble_class        <- if (is_unanswerable_msg) "chat-bubble-unanswerable" else "chat-bubble-bot"
        
        mode_label <- if (!is.null(m$mode) && m$mode == "dual")
          tags$small(class = "tool-badge", "two-llm pipeline") else NULL
        
        header_row <- if (!is.null(m$tool)) {
          div(style = "display:flex; align-items:center; gap:6px; margin-bottom:4px;",
              tags$small(class = "tool-badge", style = "margin:0;",
                         paste0("tool: ", m$tool)),
              tool_confidence(m$tool))
        } else NULL
        
        rendered <- HTML(gsub("\\*\\*(.*?)\\*\\*", "<strong>\\1</strong>",
                              gsub("\n", "<br>", m$text)))
        
        detail <- tool_detail_panel(m$tool, m$params)
        
        div(class = bubble_class, mode_label, header_row, rendered, detail)
      }
    })
    
    loading_bubble <- if (rv$is_loading) {
      list(
        div(class = "chat-bubble-bot",
            style = "background:#f0f9f8; border-color:#c8e6e3;",
            div(style = "display:flex; align-items:center; gap:10px; padding:4px 0;",
                tags$span(style = "width:14px; height:14px; border-radius:50%; background:#E63946;
                                   display:inline-block; animation:mine-bounce 1.2s infinite ease-in-out;
                                   animation-delay:0s;"),
                tags$span(style = "width:14px; height:14px; border-radius:50%; background:#2A9D8F;
                                   display:inline-block; animation:mine-bounce 1.2s infinite ease-in-out;
                                   animation-delay:0.2s;"),
                tags$span(style = "width:14px; height:14px; border-radius:50%; background:#E76F51;
                                   display:inline-block; animation:mine-bounce 1.2s infinite ease-in-out;
                                   animation-delay:0.4s;"),
                tags$span(style = "color:#2A9D8F; font-size:0.85em; font-weight:600; margin-left:2px;",
                          "Working...")))
      )
    } else NULL
    
    tags$div(els, loading_bubble,
             tags$script(HTML("
               (function() {
                 var el = document.getElementById('chat_scroll');
                 if (!el) return;
                 el.scrollTop = el.scrollHeight;
                 if (!el._obs) {
                   el._obs = new MutationObserver(function() {
                     el.scrollTop = el.scrollHeight;
                   });
                   el._obs.observe(el, { childList: true, subtree: true });
                 }
               })();
             ")))
  })
  
  output$result_table <- renderDT({
    req(!is.null(rv$last_df))
    datatable(rv$last_df,
              options = list(pageLength = 15, scrollX = TRUE, dom = "frtip",
                             language = list(search = "Search:",
                                             info = "Showing _START_ to _END_ of _TOTAL_ rows",
                                             paginate = list(previous = "Previous", `next` = "Next"))),
              rownames = FALSE, class = "table-sm table-striped table-hover")
  })
  
  # ── Export ───────────────────────────────────────────────────────────────────
  
  observeEvent(input$export_btn, {
    has_table <- !is.null(rv$last_df)
    showModal(modalDialog(
      title = "Export Session",
      size  = "s",
      easyClose = TRUE,
      footer = tagList(
        modalButton("Cancel"),
        downloadButton("do_export", "Download", class = "btn btn-primary btn-sm")
      ),
      div(class = "export-section-label", "Format"),
      radioButtons("export_format", label = NULL,
                   choices = c(
                     "Plain text (.txt)"   = "txt",
                     "CSV (.csv)"          = "csv",
                     "HTML report (.html)" = "html"
                   ),
                   selected = "txt"),
      div(class = "export-section-label", "Include"),
      checkboxGroupInput("export_content", label = NULL,
                         choices = c(
                           "Chat log"      = "chat",
                           "Results table" = "table"
                         ),
                         selected = c("chat", if (has_table) "table")),
      if (!has_table)
        tags$small(style = "color:#aaa;",
                   "No results table available yet in this session.")
    ))
  })
  
  build_chat_txt <- function() {
    msgs <- rv$messages
    if (length(msgs) == 0) return("(no conversation)")
    lines <- vapply(msgs, function(m) {
      role <- if (m$role == "user") "You" else "Assistant"
      tool_info <- if (!is.null(m$tool)) paste0(" [tool: ", m$tool, "]") else ""
      paste0("[", role, tool_info, "]\n", m$text)
    }, character(1))
    paste(lines, collapse = "\n\n---\n\n")
  }
  
  build_table_txt <- function() {
    df <- rv$last_df
    if (is.null(df)) return("(no results table)")
    paste(capture.output(print(df, row.names = FALSE)), collapse = "\n")
  }
  
  build_chat_html <- function() {
    msgs <- rv$messages
    if (length(msgs) == 0) return("<p><em>No conversation.</em></p>")
    parts <- lapply(msgs, function(m) {
      if (m$role == "user") {
        paste0('<div style="text-align:right;margin:6px 0;">',
               '<span style="background:#2A9D8F;color:white;padding:6px 12px;',
               'border-radius:14px;display:inline-block;">',
               htmltools::htmlEscape(m$text), '</span></div>')
      } else {
        tool_line <- if (!is.null(m$tool))
          paste0('<div style="font-size:0.78em;color:#888;margin-bottom:4px;">tool: ',
                 htmltools::htmlEscape(m$tool), '</div>') else ""
        txt <- gsub("\n", "<br>", htmltools::htmlEscape(m$text))
        txt <- gsub("\\*\\*(.*?)\\*\\*", "<strong>\\1</strong>", txt)
        paste0('<div style="background:#f8f9fa;border:1px solid #dee2e6;',
               'padding:10px 14px;border-radius:14px;margin:6px 0;">',
               tool_line, txt, '</div>')
      }
    })
    paste(parts, collapse = "\n")
  }
  
  build_table_html <- function() {
    df <- rv$last_df
    if (is.null(df)) return("<p><em>No results table.</em></p>")
    header <- paste0("<th style='padding:4px 10px;border:1px solid #dee2e6;background:#f0f9f8;'>",
                     names(df), "</th>", collapse = "")
    rows <- apply(df, 1, function(row) {
      cells <- paste0("<td style='padding:4px 10px;border:1px solid #dee2e6;'>",
                      htmltools::htmlEscape(as.character(row)), "</td>", collapse = "")
      paste0("<tr>", cells, "</tr>")
    })
    paste0('<table style="border-collapse:collapse;font-size:0.85em;width:100%;">',
           "<thead><tr>", header, "</tr></thead><tbody>",
           paste(rows, collapse = ""), "</tbody></table>")
  }
  
  output$do_export <- downloadHandler(
    filename = function() {
      fmt   <- input$export_format %||% "txt"
      stamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
      paste0("als_session_", stamp, ".", fmt)
    },
    content = function(file) {
      fmt        <- input$export_format %||% "txt"
      content    <- input$export_content %||% "chat"
      want_chat  <- "chat"  %in% content
      want_table <- "table" %in% content
      
      if (fmt == "csv") {
        rows <- list()
        if (want_table && !is.null(rv$last_df)) rows[["table"]] <- rv$last_df
        if (want_chat) {
          chat_df <- do.call(rbind, lapply(rv$messages, function(m) {
            data.frame(
              role = m$role,
              text = m$text,
              tool = if (!is.null(m$tool)) m$tool else "",
              stringsAsFactors = FALSE
            )
          }))
          rows[["chat"]] <- chat_df
        }
        con <- file(file, open = "w")
        for (nm in names(rows)) {
          writeLines(paste0("# ", nm), con)
          write.csv(rows[[nm]], con, row.names = FALSE)
          writeLines("", con)
        }
        close(con)
        
      } else if (fmt == "html") {
        chat_block  <- if (want_chat)  build_chat_html()  else ""
        table_block <- if (want_table) build_table_html() else ""
        ts <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
        html <- paste0(
          '<!DOCTYPE html><html><head><meta charset="UTF-8">',
          '<title>ALS Variant Assistant \u2014 Session Export</title>',
          '<style>body{font-family:sans-serif;max-width:860px;margin:40px auto;color:#333;}',
          'h1{color:#2A9D8F;}h2{color:#457B9D;margin-top:30px;}',
          '.ts{color:#aaa;font-size:0.8em;}</style></head><body>',
          '<h1>Project ALS \u2014 Variant Assistant</h1>',
          '<p class="ts">Exported: ', ts, '</p>',
          if (want_chat)  paste0('<h2>Chat Log</h2>',     chat_block),
          if (want_table) paste0('<h2>Results Table</h2>', table_block),
          '</body></html>'
        )
        writeLines(html, file)
        
      } else {
        sections <- character(0)
        ts <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
        sections <- c(sections,
                      paste0("Project ALS \u2014 Variant Assistant\nSession export: ", ts, "\n",
                             strrep("=", 50)))
        if (want_chat)  sections <- c(sections,
                                      paste0("CHAT LOG\n", strrep("-", 40), "\n", build_chat_txt()))
        if (want_table) sections <- c(sections,
                                      paste0("RESULTS TABLE\n", strrep("-", 40), "\n", build_table_txt()))
        writeLines(paste(sections, collapse = "\n\n"), file)
      }
    }
  )
}

shinyApp(ui, server)