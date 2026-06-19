# ─────────────────────────────────────────────────────────────────────────────
# Project ALS  —  Variant Assistant v2 — Pipeline Logic
# Sourced by: app2.R (Shiny UI) and backend_agentic.R (benchmark)
#
# Contains: config, helpers, tool descriptions, nonsense gate,
#           classify_complexity, classify_tool, summarize_result,
#           run_agentic_pipeline, run_single_pipeline, run_dual_pipeline,
#           run_pipeline (master dispatcher)
# ─────────────────────────────────────────────────────────────────────────────

library(httr2)
library(jsonlite)

## ── Config ───────────────────────────────────────────────────────────────────
MCP_BASE   <- "http://localhost:8008"
OLLAMA_URL <- "http://localhost:11434"
ORCH_MODEL      <- "llama3.1:70b"
DECOMPOSE_MODEL <- ORCH_MODEL   ## CPU-only server: switching models causes resource
                                  ## contention between concurrent llama-server processes.
                                  ## Keep everything on one model to avoid this.
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
    label = "Single — llama3.1:70b",
    desc  = "Good tool selection, auto-routes simple/complex."
  ),
  dual_duckdb = list(
    mode = "dual", orch = ORCH_MODEL, sub = "duckdb-nsql",
    label = "Two LLM — llama3.1:70b + duckdb-nsql ★",
    desc  = "SQL specialist activates for run_variant_query. Best for complex SQL."
  ),
  dual_llama = list(
    mode = "dual", orch = ORCH_MODEL, sub = ORCH_MODEL,
    label = "Two LLM — llama3.1:70b + llama3.1:70b",
    desc  = "Both steps use same model. Good for reasoning-heavy questions."
  ),
  dual_adaptive = list(
    mode = "dual_adaptive", orch = ORCH_MODEL,
    sub_sql = "duckdb-nsql", sub_reason = ORCH_MODEL,
    label = "Adaptive — llama3.1:70b + [duckdb-nsql | llama3.1:70b] ★",
    desc  = "LLM1 selects: duckdb-nsql for SQL queries, llama3.1:70b for tool reasoning."
  )
)

# ══════════════════════════════════════════════════════════════════════════════
# HELPERS
# ══════════════════════════════════════════════════════════════════════════════

# ══════════════════════════════════════════════════════════════════════════════
# MODEL WARMUP
# Pre-loads models into Ollama's memory before the first real question.
# Prevents the "Ollama not reachable" timeouts caused by cold-start model
# loading when switching between DECOMPOSE_MODEL (8b) and ORCH_MODEL (70b).
# ══════════════════════════════════════════════════════════════════════════════

## Default Ollama keep_alive behaviour (5m) — NOT extended, because on this
## CPU-only server, keeping multiple models loaded simultaneously causes
## resource contention rather than helping. Only one model (70b) is used
## throughout the pipeline now, so this matters less, but we don't force
## long residency to avoid memory pressure issues.
OLLAMA_KEEP_ALIVE <- "5m"

warmup_model <- function(model, timeout_sec = 120) {
  body <- list(
    model       = model,
    prompt      = "ping",
    stream      = FALSE,
    keep_alive  = OLLAMA_KEEP_ALIVE,
    options     = list(num_predict = 1)
  )
  start <- Sys.time()
  result <- tryCatch({
    resp <- request(OLLAMA_URL) |>
      req_url_path("/api/generate") |>
      req_body_json(body) |>
      req_timeout(timeout_sec) |>
      req_perform()
    resp_body_json(resp)
    elapsed <- round(as.numeric(Sys.time() - start, units = "secs"), 1)
    list(ok = TRUE, model = model, elapsed = elapsed)
  }, error = function(e) {
    elapsed <- round(as.numeric(Sys.time() - start, units = "secs"), 1)
    list(ok = FALSE, model = model, elapsed = elapsed, error = e$message)
  })
  result
}

## Warm up all models used by the pipeline. Call once at startup —
## before the Shiny app accepts input, or before a benchmark run begins.
## status_fn: optional callback(msg) for UI progress updates, e.g. Shiny progress
warmup_all_models <- function(models = NULL, status_fn = NULL) {
  if (is.null(models)) {
    models <- unique(c(ORCH_MODEL, DECOMPOSE_MODEL))
  }

  report <- list()
  for (m in models) {
    msg <- paste0("Warming up ", m, "...")
    cat("[WARMUP]", msg, "\n")
    if (!is.null(status_fn)) status_fn(msg)

    res <- warmup_model(m)
    report[[m]] <- res

    if (res$ok) {
      cat("[WARMUP] ", m, "ready in", res$elapsed, "sec\n")
    } else {
      cat("[WARMUP] ", m, "FAILED:", res$error, "\n")
    }
  }

  all_ok <- all(sapply(report, function(r) r$ok))
  if (!is.null(status_fn)) {
    status_fn(if (all_ok) "All models warmed up" else "Warmup had issues — see log")
  }
  cat("[WARMUP] Complete. All models ready:", all_ok, "\n")

  list(ok = all_ok, models = report)
}

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
               keep_alive = OLLAMA_KEEP_ALIVE,
               options = list(temperature = if (json_mode) 0.0 else 0.2,
                              num_predict = num_predict))
  if (!is.null(system_prompt)) body$system <- system_prompt
  if (json_mode)               body$format <- "json"
  ## NOTE: errors are NOT caught here — they must propagate up to call_ollama()
  ## so its retry logic actually triggers. Catching here was silently disabling retries.
  resp <- request(OLLAMA_URL) |>
    req_url_path("/api/generate") |>
    req_body_json(body) |>
    req_timeout(180) |>
    req_perform()
  resp_body_json(resp)$response
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

## ── Result sanity checker ────────────────────────────────────────────────────
## Returns a warning string if result looks obviously wrong, NULL if ok
check_result_sanity <- function(raw_result, tool, params) {
  if (is.null(raw_result) || nchar(raw_result) == 0) return("Empty result")
  
  parsed <- tryCatch(fromJSON(raw_result, simplifyVector = TRUE), error = function(e) NULL)
  if (is.null(parsed)) return(NULL)
  
  ## Check for 1802 (total row count) appearing as an answer value
  result_str <- as.character(raw_result)
  
  ## If any numeric value equals 1802 and this is a filtered query — suspicious
  if (grepl('"1802"', result_str) || grepl(':1802', result_str) || grepl(':1802,', result_str)) {
    ## 1802 is only valid for "how many variants total" questions
    sql <- params$sql %||% ""
    has_where <- grepl("WHERE", sql, ignore.case = TRUE)
    has_gene_filter <- grepl("gene_name=", sql, ignore.case = TRUE)
    if (has_where || has_gene_filter) {
      return("Result contains 1802 (total row count) despite having filters — SQL filter likely failed")
    }
  }
  
  ## For carrier queries: more than 10 unique IIDs is impossible (only 10 named individuals)
  if (grepl("get_carriers_with_phenotype", tool) || grepl("IID", result_str)) {
    n_iid <- length(gregexpr('"IID"', result_str)[[1]])
    if (n_iid > 10) return(paste("Carrier query returned", n_iid, "results — expected max 10"))
  }
  
  ## For gene-specific queries, result spanning 12 genes suggests missing WHERE
  if (!is.null(params$sql) && grepl("gene_name=", params$sql) && is.data.frame(parsed)) {
    if ("gene_name" %in% names(parsed) && length(unique(parsed$gene_name)) == 12) {
      return("Gene-specific query returned all 12 genes — WHERE clause may be missing")
    }
  }
  
  NULL
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
# NONSENSE / RELEVANCE CHECK
# ══════════════════════════════════════════════════════════════════════════════

## Known dataset keywords — if any appear the input is at least partially relevant
DATASET_KEYWORDS <- c(
  "variant", "gene", "allele", "frequency", "impact", "burden",
  "cadd", "sift", "polyphen", "chromosome", "chrom", "position",
  "homozygous", "heterozygous", "carrier", "als", "control",
  "nek1", "sod1", "tardbp", "fus", "abca4", "optn", "tbk1",
  "ubqln2", "pex5", "rin3", "il3ra", "znf483", "cyp19a1",
  "population", "cohort", "sex", "female", "male", "age",
  "synonymous", "moderate", "high impact", "deleterious",
  "pathogenic", "clinvar", "maf", "linkage", "burden test",
  "rvat", "association", "p-value", "odds ratio",
  "als_1", "als_2", "als_3", "als_4", "als_5",
  "control_1", "control_2", "control_3", "control_4", "control_5"
)

check_nonsense <- function(question) {
  ## Returns: "valid", "pure_nonsense", or "unresolvable"
  
  q_lower <- tolower(trimws(question))
  
  ## Empty or whitespace only
  if (nchar(q_lower) == 0) return("pure_nonsense")
  
  ## Very short inputs with no recognisable words (< 3 chars or pure symbols)
  if (nchar(q_lower) < 4 && !grepl("[a-z]", q_lower)) return("pure_nonsense")
  
  ## Check if ANY dataset keyword is present
  has_keyword <- any(sapply(DATASET_KEYWORDS, function(kw) {
    grepl(kw, q_lower, fixed = TRUE)
  }))
  
  ## Fast regex checks for obviously valid question patterns
  is_question <- grepl(
    "how many|which|what|where|list|show|count|give|compare|is there|are there|find|run|get",
    q_lower, perl = TRUE
  )
  
  ## If it has a keyword AND looks like a question → valid, skip LLM check
  if (has_keyword && is_question) return("valid")
  
  ## If it has a keyword but is not phrased as a question → still try (e.g. "SOD1 burden")
  if (has_keyword) return("valid")
  
  ## Secondary check: questions that have keywords but are too vague or impossible
  vague_patterns <- c(
    "most interesting variant",
    "most interesting.*dataset",
    "important.*variant",    ## too vague without criteria
    "should we follow up",   ## wet-lab decision
    "good enough to find the cause",  ## methodological judgement
    "affect splicing"        ## no splicing annotation in DB
  )
  for (pat in vague_patterns) {
    if (grepl(pat, q_lower, perl = TRUE)) {
      cat("[NONSENSE] Vague/impossible pattern matched:", pat, "\n")
      return("pure_nonsense")
    }
  }

  ## No keywords — use LLM to decide if it is a coherent question about genomics/ALS
  sys <- paste0(
    "You are a gatekeeper for an ALS genomic variant database chatbot. ",
    "Decide if the user input is a coherent question or request about genomic variants, genes, ",
    "allele frequencies, patients, or the ALS dataset. ",
    "Output ONLY one word: valid OR nonsense. Nothing else. ",
    "Examples of valid: \'How many variants in SOD1?\' \'Run a burden test\' \'What is the MAF in NEK1?\' ",
    "Examples of nonsense: \'asdfgh\' \'hello world\' \'what is the weather\' \'kjhsdakjhsd\'"
  )
  raw <- call_ollama(question, system_prompt = sys,
                     model = ORCH_MODEL, num_predict = 5)
  raw <- trimws(tolower(raw))
  
  if (grepl("valid", raw)) return("valid")
  return("pure_nonsense")
}

## ── Nonsense response helpers ─────────────────────────────────────────────
nonsense_response <- function(type) {
  if (type == "pure_nonsense") {
    paste0(
      "That doesn\'t look like a question I can help with. ",
      "Please ask something about the ALS variant database — for example: ",
      "\'How many high-impact variants are in SOD1?\' or \'Run a burden test for NEK1.\'")
  } else {
    paste0(
      "I wasn\'t able to find relevant data for that question in this database. ",
      "Try asking about specific genes, variant annotations, allele frequencies, or burden tests — ",
      "for example: \'What is the average CADD score for high-impact variants in ABCA4?\'")
  }
}

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

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1 — ROUTER
# Picks server + tool only. No SQL. Explicit rules for each tool.
# ══════════════════════════════════════════════════════════════════════════════

# ══════════════════════════════════════════════════════════════════════════════
# STEP 0 — QUESTION DECOMPOSITION
# Before routing, the model reasons about WHAT KIND of computation is needed.
# This reasoning is then passed into the router as context, so the router
# isn't just pattern-matching question text against tool names — it's routing
# based on an explicit understanding of the computation.
# ══════════════════════════════════════════════════════════════════════════════

## Keywords that signal a question may need per-entity grouping or comparison.
## Only these trigger decomposition — simple single-fact questions skip it.
DECOMPOSE_TRIGGERS <- c(
  "each", "every", "per ", "per-", "for each", "for every",
  "all five", "all 5", "all ten", "all 10",
  "compare", "comparison", "difference", "versus", "vs ",
  "distribution", "breakdown", "proportion.*per", "ratio per",
  "highest.*among", "lowest.*among", "most.*among",
  "both", "simultaneously", "at the same time",
  "Europeans", "African", "Asian", "population",
  "splicing", "protein domain", "wet.lab", "de novo",
  "pathogenic", "causative", "clinical", "onset"
)

needs_decompose <- function(question) {
  q <- tolower(question)
  any(sapply(DECOMPOSE_TRIGGERS, function(pat) grepl(pat, q, perl = TRUE)))
}

decompose_question <- function(question, orch_model = DECOMPOSE_MODEL) {
  sys <- paste0(
    "You analyse a question about a genomic database BEFORE deciding how to answer it.\n",
    "Think about what KIND of computation is actually needed — not which tool to use yet.\n\n",

    "Output ONLY JSON with these keys:\n",
    "  computation: one of 'single_lookup' | 'aggregate' | 'per_entity_breakdown' | ",
    "'comparison' | 'filter_count' | 'statistical_test' | 'impossible'\n",
    "  entities_involved: list of distinct things being counted/compared (e.g. genes, patients, chromosomes)\n",
    "  needs_grouping: true if the answer requires one result PER entity (e.g. per patient, per gene, per chromosome)\n",
    "  reasoning: one sentence explaining the computation\n\n",

    "DEFINITIONS:\n",
    "  single_lookup: one fact about one specific thing (e.g. 'how many variants in SOD1')\n",
    "  aggregate: one number summarising the whole dataset (e.g. 'total variants', 'average CADD')\n",
    "  per_entity_breakdown: a SEPARATE result needed for EACH of several entities ",
    "(e.g. 'how many variants does EACH patient carry', 'burden PER gene') — needs_grouping=true\n",
    "  comparison: comparing two specific named groups or values (e.g. 'cases vs controls', 'gene A vs gene B')\n",
    "  filter_count: counting rows matching specific conditions (e.g. 'variants where X and Y')\n",
    "  statistical_test: requires a formal statistical method (burden test, p-value, MAF, LD)\n",
    "  impossible: data needed does not exist in this database (population-specific, clinical, wet-lab)\n\n",

    "EXAMPLES:\n",
    "  Q: 'How many variants in SOD1?' → {computation: single_lookup, entities_involved: [SOD1], needs_grouping: false}\n",
    "  Q: 'For each of the 5 ALS patients, how many high-impact variants in TARDBP, SOD1, or NEK1?'\n",
    "    → {computation: per_entity_breakdown, entities_involved: [ALS_1,ALS_2,ALS_3,ALS_4,ALS_5,TARDBP,SOD1,NEK1],\n",
    "       needs_grouping: true, reasoning: 'needs a separate count per patient across 3 genes — SQL with per-patient columns'}\n",
    "  Q: 'Which gene shows the greatest difference in burden between cases and controls?'\n",
    "    → {computation: comparison, entities_involved: [genes, cases, controls], needs_grouping: true,\n",
    "       reasoning: 'needs per-gene aggregation then comparison — GROUP BY gene_name with ABS difference'}\n",
    "  Q: 'Run a burden test for SOD1' → {computation: statistical_test, entities_involved: [SOD1]}\n",
    "  Q: 'What is the AF in Europeans?' → {computation: impossible, reasoning: 'no population-specific AF in database'}\n"
  )

  raw    <- call_ollama(question, system_prompt = sys,
                        model = orch_model, json_mode = TRUE, num_predict = 200)
  parsed <- parse_json_response(raw)

  if (is.null(parsed) || is.null(parsed$computation)) {
    cat("[DECOMPOSE] Failed to parse, defaulting to filter_count\n")
    return(list(computation = "filter_count", needs_grouping = FALSE,
                entities_involved = character(0), reasoning = "decomposition failed"))
  }

  cat("[DECOMPOSE] computation:", parsed$computation,
      "| needs_grouping:", parsed$needs_grouping %||% FALSE,
      "| reasoning:", parsed$reasoning %||% "", "\n")

  list(
    computation       = parsed$computation,
    needs_grouping     = isTRUE(parsed$needs_grouping),
    entities_involved  = parsed$entities_involved,
    reasoning          = parsed$reasoning %||% ""
  )
}

route_question <- function(question, entities, decomp = NULL, orch_model = ORCH_MODEL) {
  sys <- paste0(
    "You are a tool router for an ALS genomic variant database.\n",
    "Pick the RIGHT tool for the question. Output ONLY JSON: {server, tool, params}\n",
    "params should NOT include sql — that is generated separately.\n\n",

    "TOOLS (server/tool → when to use):\n",
    "variant_analysis/count_variants_in_gene         → 'how many variants in [gene]'\n",
    "variant_analysis/get_high_impact_variants_in_gene → 'show/list high-impact in [gene]'\n",
    "variant_analysis/count_sift_deleterious_in_gene  → 'SIFT deleterious in [gene]'\n",
    "variant_analysis/get_highest_af_variant          → 'highest allele frequency variant'\n",
    "variant_analysis/get_als_carrier_stats           → 'what % variants carried by ALS'\n",
    "variant_analysis/run_variant_query               → any other count/filter/aggregate on variants\n",
    "genotype_analysis/get_total_burden_cases_vs_controls → 'total allele burden cases vs controls'\n",
    "genotype_analysis/get_dosage_ratio_by_gene       → 'ratio / enrichment per gene'\n",
    "genotype_analysis/get_carriers_by_gene           → 'carriers in gene'\n",
    "genotype_analysis/get_case_enriched_variants     → 'case-enriched variants'\n",
    "db_exploration/get_database_info                 → 'how many ALS cases/controls in database'\n",
    "db_exploration/get_database_limitations          → anything NOT in database (pathogenicity/population AF/wet-lab/splicing/de novo/onset/domain)\n",
    "phenotype_data/get_age_distribution              → 'average age of ALS cases'\n",
    "phenotype_data/get_sex_distribution              → 'sex breakdown of samples'\n",
    "phenotype_data/get_population_counts             → 'samples per population'\n",
    "phenotype_data/get_carriers_with_phenotype       → 'female/male/SAS/EUR carriers in [gene]'\n",
    "phenotype_data/run_phenotype_query               → any SQL on pheno table (age/sex/pop filters)\n",
    "clinvar_annotation/get_clinvar_for_variant       → 'ClinVar / pathogenic / reported for VAR_id N'\n",
    "rvat_analysis/run_burden_test                    → 'burden test / association / p-value for [gene]'\n",
    "rvat_analysis/run_burden_all_genes               → 'burden test all genes / most significant genes'\n",
    "rvat_analysis/run_single_variant_test            → 'per-variant significance / most significant variants in [gene]'\n",
    "rvat_analysis/get_maf_by_impact                  → 'MAF / minor allele frequency for [gene]'\n",
    "rvat_analysis/get_ld_matrix                      → 'linkage disequilibrium / LD between variants'\n",
    "rvat_analysis/get_cohort_summary                 → 'cohort size / sample counts'\n\n",

    "ROUTING RULES:\n",
    "  - run_variant_query ALWAYS uses server=variant_analysis, NEVER genotype_analysis\n",
    "  - 'SIFT tolerated / SIFT=T / tolerated variants' → run_variant_query WHERE SIFT='T'\n",
    "  - 'SIFT deleterious without a specific gene' → run_variant_query WHERE SIFT='D'\n",
    "  - count_sift_deleterious_in_gene ONLY when a specific gene name is given\n",
    "  - 'greatest DIFFERENCE in burden' → variant_analysis/run_variant_query\n",
    "  - 'how many variants total in dataset' → run_variant_query\n",
    "  - 'ClinVar' without a specific VAR_id number → get_database_limitations\n",
    "  - 'population-specific AF / in Europeans / in SAS' → get_database_limitations\n",
    "  - 'splicing / protein domain / wet-lab / de novo / onset / pathogenic without VAR_id' → get_database_limitations\n",
    "  - 'Is X an ALS gene / is this gene associated with ALS' → get_database_limitations\n",
    "  - 'which variants are important / should we follow up' → get_database_limitations\n",
    "  - Any question about sex/age/population of carriers → get_carriers_with_phenotype\n",
    "  - If computation=per_entity_breakdown: this needs a GROUP BY query → run_variant_query, ",
    "NEVER a single-summary tool like get_total_burden_cases_vs_controls\n",
    "  - If computation=comparison and needs_grouping=true: needs per-group aggregation → run_variant_query, ",
    "NOT a tool that returns one overall total\n",
    "  - If computation=aggregate and entities_involved has no specific gene: likely run_variant_query on whole dataset\n\n",

    "PARAMS to include (no sql):\n",
    "  single gene tools: {gene: 'UPPERCASE_NAME'} — ONLY when question mentions exactly one gene\n",
    "  multiple genes OR complex filter → params: {} — SQL generator handles it\n",
    "  per-patient breakdown → params: {} — SQL generator handles it\n",
    "  carriers: {gene, impact: 'high_moderate', sex: 1or2 if specified, population: 'SAS' if specified}\n",
    "  clinvar: {var_id: INTEGER}\n",
    "  rvat burden: {gene, test: 'firth', impact_filter: 'high_moderate'}\n",
    "  rvat maf: {gene, impact_filter: 'moderate'}\n",
    "  NEVER pass multiple genes as separate params — use {} and let SQL handle it\n\n",

    if (!is.na(entities$gene))       paste0("Detected gene: ", entities$gene, "\n") else "",
    if (!is.na(entities$sex))        paste0("Detected sex: ", as.integer(entities$sex), " (1=female/2=male)\n") else "",
    if (!is.na(entities$population)) paste0("Detected population: '", entities$population, "'\n") else "",
    if (!is.null(decomp)) paste0(
      "Computation type identified: ", decomp$computation %||% "unknown",
      " | needs per-entity grouping: ", decomp$needs_grouping %||% FALSE,
      " | reasoning: ", decomp$reasoning %||% "", "\n"
    ) else "",
    "Question: ", question
  )

  raw    <- call_ollama(question, system_prompt = sys,
                        model = orch_model, json_mode = TRUE, num_predict = 200)
  parsed <- parse_json_response(raw)

  if (is.null(parsed) || is.null(parsed$tool)) {
    return(list(ok = FALSE, error = paste("Routing failed:", raw)))
  }

  # Normalise server/tool
  tool_raw   <- parsed$tool %||% ""
  server_raw <- parsed$server %||% ""
  if (grepl("/", tool_raw)) {
    parts <- strsplit(tool_raw, "/")[[1]]
    server <- parts[1]; tool <- paste(parts[-1], collapse = "/")
  } else {
    server <- if (nchar(server_raw) > 0) server_raw else "variant_analysis"
    tool   <- tool_raw
  }
  params <- if (is.null(parsed$params)) list() else as.list(parsed$params)
  params <- params[!sapply(params, function(v) is.null(v) || identical(v, ""))]

  ## Structural correction: run_variant_query only exists under variant_analysis.
  ## This is a fact about the system, not a routing preference — always enforce it.
  if (tool == "run_variant_query" && server != "variant_analysis") {
    cat("[ROUTER] Correcting server for run_variant_query:", server, "→ variant_analysis\n")
    server <- "variant_analysis"
  }
  if (tool == "run_phenotype_query" && server != "phenotype_data") {
    cat("[ROUTER] Correcting server for run_phenotype_query:", server, "→ phenotype_data\n")
    server <- "phenotype_data"
  }

  cat("[ROUTER] →", server, "/", tool, "| params:", paste(names(params), unlist(params), sep = "=", collapse = ", "), "\n")
  list(ok = TRUE, server = server, tool = tool, params = params)
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 2 — SQL GENERATOR
# Only called when tool is run_variant_query or run_phenotype_query.
# Uses a dedicated SQL-focused prompt. Optionally uses duckdb-nsql.
# ══════════════════════════════════════════════════════════════════════════════

SQL_SCHEMA <- paste0(
  "SQLite database. Table: varInfo_synthetic\n",
  "Columns: gene_name TEXT, VAR_id INTEGER, CHROM TEXT, POS TEXT, REF TEXT, ALT TEXT,\n",
  "  AF TEXT (global allele freq, missing='.'),\n",
  "  HighImpact TEXT ('0'/'1'), ModerateImpact TEXT ('0'/'1'), Synonymous TEXT ('0'/'1'),\n",
  "  CADDphred TEXT (missing='.'), SIFT TEXT ('D'/'T'/'.'), PolyPhen TEXT ('D'/'P'/'B'/'.'),\n",
  "  ALS_1..ALS_5 INTEGER (0=ref/1=het/2=hom), Control_1..Control_5 INTEGER\n",
  "Table: pheno — IID TEXT, sex INTEGER (1=female/2=male), pop TEXT, superPop TEXT, age REAL, pheno INTEGER (1=case/0=ctrl)\n\n",
  "RULES (SQLite only — no DuckDB syntax):\n",
  "  1. Missing = '.' not NULL → use !='.', NEVER IS NOT NULL\n",
  "  2. HighImpact/ModerateImpact/Synonymous are TEXT → WHERE HighImpact='1'\n",
  "  3. Numeric: CAST(CADDphred AS REAL), CAST(AF AS REAL)\n",
  "  4. CHROM: 'chr1','chrX' — always include prefix\n",
  "  5. Gene: gene_name='SOD1' — always single-quote\n",
  "  6. No ::REAL or ::INTEGER — use CAST() instead\n",
  "  7. Per-sample burden: SUM(ALS_1+ALS_2+ALS_3+ALS_4+ALS_5)\n",
  "  8. Private variants: ((ALS_1>0 AND ALS_2=0 AND ALS_3=0 AND ALS_4=0 AND ALS_5=0) OR ...) AND Control_1=0...\n",
  "  9. Absolute difference: ABS(SUM(ALS_1+ALS_2+ALS_3+ALS_4+ALS_5) - SUM(Control_1+...)) AS abs_diff\n",
  " 10. PolyPhen codes: D=damaging, P=possibly_damaging, B=benign — single letter only\n",
  " 11. For DISTINCT list: SELECT DISTINCT gene_name (not just SELECT gene_name)\n",
  " 12. Always include GROUP BY when using aggregate functions with other columns\n",
  " 13. AGGREGATE IN WHERE IS INVALID — use a subquery: SELECT COUNT(*) FROM (SELECT VAR_id, SUM(ALS_1+ALS_2+ALS_3+ALS_4+ALS_5) AS s FROM varInfo_synthetic GROUP BY VAR_id) WHERE s > 0\n"
)

generate_sql <- function(question, table = "varInfo_synthetic",
                         sql_model = ORCH_MODEL,
                         orch_model = ORCH_MODEL,
                         decomp = NULL) {
  sys <- paste0(
    "You generate SQLite SQL for an ALS genomic variant database.\n",
    "Output ONLY the SQL query. No explanation. No markdown. No backticks.\n",
    "Start directly with SELECT. Write the COMPLETE query — never truncate.\n\n",
    "FORBIDDEN:\n",
    "  GROUP BY ALL (DuckDB only), ::REAL (use CAST()), IS NULL/IS NOT NULL (use !='.'),\n",
    "  joining pheno table when target is varInfo_synthetic, incomplete/truncated queries\n\n",
    SQL_SCHEMA
  )

  decomp_hint <- if (!is.null(decomp)) {
    paste0(
      "Computation type: ", decomp$computation %||% "unknown", "\n",
      if (isTRUE(decomp$needs_grouping))
        "IMPORTANT: This needs a SEPARATE result per entity — use GROUP BY, do not collapse to one row.\n"
      else "",
      if (identical(decomp$computation, "per_entity_breakdown"))
        "IMPORTANT: Use individual columns (e.g. ALS_1, ALS_2...) in SELECT/CASE, one output column or row per entity.\n"
      else "",
      if (identical(decomp$computation, "comparison"))
        "IMPORTANT: Compute both sides of the comparison in the same query, then compare (e.g. ABS(a-b)).\n"
      else ""
    )
  } else ""

  prompt <- paste0(
    "Generate a SQLite query for this question:\n", question, "\n\n",
    decomp_hint,
    "Target table: ", table, "\n",
    "Output ONLY the SQL. Start with SELECT."
  )

  # Try SQL specialist first, fall back to orchestrator
  raw <- call_ollama(prompt, system_prompt = sys, model = sql_model,
                     json_mode = FALSE, num_predict = 400)
  raw <- trimws(gsub("```sql|```", "", raw))

  # Validate basic SQL structure
  is_valid_sql <- grepl("^SELECT", raw, ignore.case = TRUE) &&
                  !grepl("::", raw, fixed = TRUE) &&
                  nchar(raw) > 10

  if (!is_valid_sql) {
    cat("[SQL-GEN] First attempt invalid (", substr(raw, 1, 60), "), retrying\n")
    Sys.sleep(1)
    raw <- call_ollama(prompt, system_prompt = sys, model = orch_model,
                       json_mode = FALSE, num_predict = 400)
    raw <- trimws(gsub("```sql|```", "", raw))
  }

  cat("[SQL-GEN] Generated SQL:", substr(raw, 1, 120), "\n")
  raw
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3 — SQL VALIDATOR
# Catches common SQL errors before executing.
# Returns list(ok, sql, issue)
# ══════════════════════════════════════════════════════════════════════════════

validate_sql <- function(sql, question) {
  issues <- character(0)

  if (!grepl("^SELECT", trimws(sql), ignore.case = TRUE))
    issues <- c(issues, "Does not start with SELECT")
  if (grepl("::", sql, fixed = TRUE))
    issues <- c(issues, "Contains DuckDB cast syntax (::)")
  if (grepl("IS\\s+NOT\\s+NULL|IS\\s+NULL", sql, perl = TRUE, ignore.case = TRUE))
    issues <- c(issues, "Uses IS NULL/IS NOT NULL (use !='.') ")
  if (grepl("HighImpact\\s*=\\s*1[^']|ModerateImpact\\s*=\\s*1[^']|Synonymous\\s*=\\s*1[^']", sql, perl = TRUE))
    issues <- c(issues, "Unquoted TEXT comparison (use HighImpact='1')")
  if (grepl("QUALIFY|PIVOT|EXCLUDE|UNNEST", sql, ignore.case = TRUE))
    issues <- c(issues, "DuckDB-only clause detected")
  if (grepl("GROUP BY ALL", sql, ignore.case = TRUE))
    issues <- c(issues, "GROUP BY ALL is DuckDB syntax — not valid in SQLite")
  if (nchar(trimws(sql)) < 15 || trimws(sql) == "SELECT")
    issues <- c(issues, "SQL appears truncated or empty")
  if (grepl("FROM\\s+p\\.|JOIN\\s+pheno|p\\.gene_name", sql, perl = TRUE))
    issues <- c(issues, "SQL references pheno table alias — only varInfo_synthetic available in run_variant_query")

  if (length(issues) == 0) {
    cat("[VALIDATOR] SQL OK\n")
    return(list(ok = TRUE, sql = sql, issue = NULL))
  }

  cat("[VALIDATOR] Issues found:", paste(issues, collapse = "; "), "\n")

  # Attempt auto-fix for common issues
  fixed <- sql
  fixed <- gsub("::(REAL|INTEGER|TEXT)", " -- cast removed", fixed, perl = TRUE, ignore.case = TRUE)
  fixed <- gsub("HighImpact\\s*=\\s*1\\b", "HighImpact='1'", fixed, perl = TRUE)
  fixed <- gsub("ModerateImpact\\s*=\\s*1\\b", "ModerateImpact='1'", fixed, perl = TRUE)
  fixed <- gsub("Synonymous\\s*=\\s*1\\b", "Synonymous='1'", fixed, perl = TRUE)
  fixed <- gsub("GROUP BY ALL", "", fixed, ignore.case = TRUE)

  # Re-validate after fix
  still_bad <- grepl("::", fixed, fixed = TRUE) ||
               grepl("QUALIFY|PIVOT", fixed, ignore.case = TRUE) ||
               nchar(trimws(fixed)) < 15 ||
               grepl("FROM\\s+p\\.|JOIN\\s+pheno", fixed, perl = TRUE)

  if (still_bad) {
    return(list(ok = FALSE, sql = sql, issue = paste(issues, collapse = "; ")))
  }

  cat("[VALIDATOR] Auto-fixed SQL\n")
  list(ok = TRUE, sql = fixed, issue = paste("Auto-fixed:", paste(issues, collapse = "; ")))
}

# ══════════════════════════════════════════════════════════════════════════════
# NEW classify_tool — thin wrapper using route + generate + validate
# Replaces the old monolithic classify_tool
# ══════════════════════════════════════════════════════════════════════════════

classify_tool <- function(question, orch_model = ORCH_MODEL,
                          tool_desc = TOOL_DESCRIPTIONS_SIMPLE,
                          sql_model = ORCH_MODEL) {
  entities <- extract_entities(question)

  # Step 0: Decompose — only for questions with complexity signals
  # Simple single-fact questions skip this to save LLM calls + avoid Ollama overload
  decomp <- if (needs_decompose(question)) {
    cat("[DECOMPOSE] Triggered — question has complexity signals\n")
    d <- decompose_question(question)
    if (identical(d$computation, "impossible")) {
      return(list(ok = TRUE, server = "db_exploration", tool = "get_database_limitations",
                 params = list()))
    }
    d
  } else {
    cat("[DECOMPOSE] Skipped — simple question\n")
    NULL
  }

  # Step 1: Route — informed by the decomposition, not just question text
  route <- route_question(question, entities, decomp, orch_model)
  if (!route$ok) return(list(ok = FALSE, error = route$error))

  server <- route$server
  tool   <- route$tool
  params <- route$params

  # Step 2: Generate SQL if needed — decomposition tells the generator
  # whether it needs GROUP BY / per-entity logic
  needs_sql <- tool %in% c("run_variant_query", "run_phenotype_query")
  if (needs_sql && is.null(params$sql)) {
    target_table <- if (tool == "run_phenotype_query") "pheno" else "varInfo_synthetic"
    sql <- generate_sql(question, table = target_table,
                        sql_model = sql_model, orch_model = orch_model,
                        decomp = decomp)

    # Step 3: Validate
    val <- validate_sql(sql, question)
    if (!val$ok) {
      cat("[CLASSIFY] SQL validation failed, retrying with orchestrator\n")
      sql <- generate_sql(question, table = target_table,
                          sql_model = orch_model, orch_model = orch_model,
                          decomp = decomp)
      val <- validate_sql(sql, question)
    }
    params$sql <- val$sql
  }

  list(ok = TRUE, server = server, tool = tool, params = params)
}

# ══════════════════════════════════════════════════════════════════════════════
# SUMMARISE
# ══════════════════════════════════════════════════════════════════════════════

summarize_result <- function(question, steps_log, result_json,
                             row_count = NULL, orch_model = ORCH_MODEL) {
  sys <- paste0(
    PROMPTS$data_description, "\n\n",
    "You are a professional ALS bioinformatics assistant. ",
    "Answer in English only. ONE sentence only for count/lookup questions. ",
    "State the exact number or answer and nothing else. ",
    "ABSOLUTE RULES:\n",
    "- ONE sentence for any question asking how many, which, what number, list, or show.\n",
    "- NEVER add a second sentence that starts with: this suggests, this indicates, this may, this could, this means, these variants, this gene, highlighting.\n",
    "- NEVER say: based on our analysis, the query returned, we found X rows, this result is based on.\n",
    "- NEVER add biological commentary, disease associations, or speculation.\n",
    "- NEVER use Dutch. English only.\n",
    "- Always use exact numbers. The AF column is GLOBAL only.\n",
    "CORRECT:\n",
    "Q: How many variants in SOD1 have PolyPhen=D? A: There are 23 variants in SOD1 with a PolyPhen score of D (damaging).\n",
    "Q: Average CADD high vs moderate NEK1? A: High-impact variants in NEK1 have a mean CADD of 36.31, compared to 20.10 for moderate-impact variants.\n",
    "Q: Burden test SOD1? A: SOD1 shows a highly significant burden in ALS cases (OR = 5.9, p < 0.001), with 80 case carriers versus 53 control carriers.\n",
    "WRONG (never do this):\n",
    "- \"23 variants... This suggests SOD1 may be associated with ALS.\" WRONG — no speculation\n",
    "- \"121 variants... This indicates OPTN is a gene with a high number of variants.\" WRONG — no commentary\n",
    "- \"607 variants... This indicates a significant portion lack annotation.\" WRONG — no filler\n"
  )
  preview <- if (nchar(result_json) > 3000) {
    paste0(substr(result_json, 1, 3000), "\n... [result shortened]")
  } else result_json
  count_hint <- if (!is.null(row_count)) {
    paste0("\nNote: the result contains ", row_count, " row(s). Use this ONLY to count carriers if relevant — do NOT mention it in your answer.\n")
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
    "ANSWER IN ONE SENTENCE ONLY. State the number or finding. Do NOT add any sentence starting with: this suggests, this indicates, this may, this could, this means, these variants, this gene, this database, highlighting."
  )
  call_ollama(prompt, system_prompt = sys, model = orch_model, num_predict = 150L)
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
    "most severe", "severity",
    ## U07: LD between specific VAR_ids (no gene → get_ld_matrix always fails with 422)
    "linkage disequilibrium between var_id", "ld between var_id",
    ## N10: ALS patient listed as control (logically impossible)
    "als patient.*also listed.*control", "listed as.*control.*als",
    "which als patient is also",
    ## N05: splicing annotation not in database
    "affect splicing", "splicing.*variant", "splice.*impact",
    ## N09: CADD=0 AND HighImpact=1 is biologically contradictory — explain don't query
    "cadd score of exactly 0.*high impact", "cadd.*0.*also high impact",
    ## N13: "most interesting" is too vague — should ask for clarification
    "most interesting variant", "most interesting.*dataset"
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
  decomp    <- if (needs_decompose(question)) {
    cat("[DECOMPOSE] Triggered for agentic question\n")
    decompose_question(question)
  } else {
    cat("[DECOMPOSE] Skipped — simple agentic question\n")
    NULL
  }
  entity_hint <- paste0(
    "Extracted entities from the question:\n",
    if (!is.na(entities$gene))       paste0("  gene = '", entities$gene, "'\n") else "",
    if (!is.na(entities$sex))        paste0("  sex = ", entities$sex,
                                            " (", if (entities$sex == 1) "female" else "male", ")\n") else "",
    if (!is.na(entities$population)) paste0("  population = '", entities$population, "'\n") else "",
    "Use these EXACT values in your tool params.\n",
    "Computation type: ", decomp$computation %||% "unknown",
    " | needs per-entity grouping: ", decomp$needs_grouping %||% FALSE,
    " | ", decomp$reasoning %||% "", "\n",
    if (isTRUE(decomp$needs_grouping))
      "IMPORTANT: This needs a SEPARATE result per entity (e.g. per patient/per gene) — use a GROUP BY query via run_variant_query, NOT a single-summary tool.\n"
    else ""
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
      "You are an ALS bioinformatics assistant. Select the NEXT tool to answer the question.\n",
      "If the context already contains a complete answer, output {status:final}.\n\n",

      "DATABASE SCHEMA (varInfo_synthetic):\n",
      "  gene_name, VAR_id, CHROM (chr1/chrX), POS, REF, ALT\n",
      "  AF (TEXT global only), HighImpact/ModerateImpact/Synonymous (TEXT 0/1, missing=.)\n",
      "  CADDphred (TEXT, missing=.), SIFT (D/T/.), PolyPhen (D/P/B/.)\n",
      "  ALS_1..ALS_5, Control_1..Control_5 (INTEGER 0=ref/1=het/2=hom)\n",
      "  pheno table: IID, sex (1=female/2=male), pop, superPop, age, pheno (1=case/0=ctrl)\n\n",

      "CRITICAL SQL RULES:\n",
      "  - Missing = '.' not NULL. Use !='.', never IS NOT NULL\n",
      "  - HighImpact/ModerateImpact/Synonymous TEXT: WHERE HighImpact='1'\n",
      "  - Numeric: CAST(CADDphred AS REAL), CAST(AF AS REAL)\n",
      "  - CHROM: 'chr1','chrX' — always include prefix\n",
      "  - Gene: gene_name='SOD1' — always quote\n",
      "  - Per-sample burden: SUM(ALS_1+ALS_2+ALS_3+ALS_4+ALS_5)\n",
      "  - Private variants: ((ALS_1>0 AND ALS_2=0...) OR ...) AND Control_1=0...\n",
      "  - Absolute difference: ABS(SUM(cases) - SUM(controls))\n",
      "  - For carrier count per sample: SELECT DISTINCT gene_name WHERE ALS_x>0\n",
      "  - pheno=1 is ALS case, pheno=0 is control\n\n",

      "TOOL SELECTION:\n",
      "  SQL on varInfo_synthetic → variant_analysis/run_variant_query {sql}\n",
      "  SQL on pheno/SM tables → phenotype_data/run_phenotype_query {sql}\n",
      "  Carriers with phenotype → phenotype_data/get_carriers_with_phenotype {gene, impact, sex?, population?}\n",
      "  Burden test → rvat_analysis/run_burden_test {gene, test:firth, impact_filter:high_moderate}\n",
      "  MAF for gene → rvat_analysis/get_maf_by_impact {gene, impact_filter}\n",
      "  LD between variants → rvat_analysis/get_ld_matrix {gene, impact_filter}\n",
      "  Per-variant association → rvat_analysis/run_single_variant_test {gene}\n",
      "  ClinVar for VAR_id → clinvar_annotation/get_clinvar_for_variant {var_id}\n",
      "  Not in database → db_exploration/get_database_limitations {}\n",
      "  DB overview → db_exploration/get_database_info {}\n\n",

      "RESULT SANITY:\n",
      "  - If a count result equals 1802 (total rows), the SQL filter is wrong — do not accept it\n",
      "  - If carriers query returns more than 10, something is wrong (only 10 named individuals)\n",
      "  - If a gene-specific query returns results for all 12 genes, the WHERE clause is missing\n\n",

      if (!is.na(entities$gene))       paste0("Target gene: ", entities$gene, "\n") else "",
      if (!is.na(entities$sex))        paste0("Target sex: ", as.integer(entities$sex), " (1=female/2=male)\n") else "",
      if (!is.na(entities$population)) paste0("Target population: '", entities$population, "'\n") else "",
      "Output: {status:continue, server, tool, params} or {status:final}\n",
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
                                num_predict = 400)
    cat("[AGENTIC] Step", step, "— LLM raw decision:", raw_decision, "\n")
    decision <- parse_json_response(raw_decision)
    
    ## Check if done — but NEVER allow status=final on step 1 (forces at least one tool call)
    is_final <- is.null(decision) ||
                (!is.null(decision$status) && decision$status == "final")
    if (is_final && step == 1L) {
      cat("[AGENTIC] Step 1 — status=final blocked, forcing tool call\n")
      ## Override: treat as if no decision was made, let loop continue to step 2
      ## where context will have forced a tool call
      is_final <- FALSE
      decision$status <- "continue"
      ## If no tool specified, default to get_database_info so something fires
      if (is.null(decision$tool) || nchar(decision$tool %||% "") == 0) {
        decision$server <- "variant_analysis"
        decision$tool   <- "run_variant_query"
        decision$params <- list(sql = "SELECT COUNT(*) AS n FROM varInfo_synthetic")
      }
    }
    if (is_final) {
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
    
    ## If tool needs SQL and none provided, generate + validate it
    needs_sql <- tool %in% c("run_variant_query", "run_phenotype_query")
    if (needs_sql && is.null(params$sql)) {
      target_table <- if (tool == "run_phenotype_query") "pheno" else "varInfo_synthetic"
      sql_context  <- paste0(question, "\nContext so far:\n", substr(context, 1, 500))
      generated_sql <- generate_sql(sql_context, table = target_table,
                                    sql_model = "duckdb-nsql", orch_model = orch_model)
      val <- validate_sql(generated_sql, question)
      if (!val$ok) {
        generated_sql <- generate_sql(sql_context, table = target_table,
                                      sql_model = orch_model, orch_model = orch_model)
        val <- validate_sql(generated_sql, question)
      }
      params$sql <- val$sql
      cat("[AGENTIC] Step", step, "— SQL generated for", tool, "\n")
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
    
    ## Sanity check result — warn if obviously wrong
    sanity_warn <- check_result_sanity(raw_result, step_label, params)
    if (!is.null(sanity_warn)) {
      cat("[AGENTIC] Step", step, "— SANITY WARNING:", sanity_warn, "\n")
      context <- paste0(context, "\nWARNING: ", sanity_warn,
                        " — reconsider the SQL or tool choice.\n")
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
  
  sanity_warn <- check_result_sanity(raw_result, paste0(server, "/", tool), params)
  if (!is.null(sanity_warn)) cat("[SIMPLE] SANITY WARNING:", sanity_warn, "\n")
  
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
  

  ## SQL already generated + validated by classify_tool (route → generate → validate)
  cat("[DUAL] Tool:", server, "/", tool, "| SQL ready:", !is.null(params$sql), "\n")

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
  
  ## ── Step 0: Nonsense / relevance gate ─────────────────────────────────
  if (!is.null(progress_fn)) progress_fn("Checking question...", 0)
  nonsense_type <- check_nonsense(question)
  if (nonsense_type != "valid") {
    cat("[PIPELINE] Nonsense gate fired:", nonsense_type, "\n")
    msg <- nonsense_response(nonsense_type)
    return(list(ok = TRUE, text = msg, tool = NULL,
                params = list(), df = NULL, mode = "simple", steps = 0,
                complexity = nonsense_type))
  }
  
  ## ── Step 1: Hard unanswerable pre-check ───────────────────────────────
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