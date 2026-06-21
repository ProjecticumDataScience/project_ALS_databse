## ============================================================
## 01_benchmark.R — Agentic pipeline benchmark (full question set)
## 111 questions across 9 categories
## ============================================================

if (!exists("BACKEND"))    BACKEND    <- "agentic_single"
if (!exists("script_dir")) script_dir <- getwd()

source(file.path(script_dir, "backend_agentic.R"))
cat("Backend loaded:", BACKEND, "\n")

stopifnot(file.exists(path.expand(PROMPTS_FILE)))
raw   <- paste(readLines(path.expand(PROMPTS_FILE)), collapse = "\n")
parts <- strsplit(raw, "===EXTRA_INSTRUCTIONS===")[[1]]
data_description   <- trimws(sub(".*===DATA_DESCRIPTION===\n", "", parts[1]))
extra_instructions <- trimws(parts[2])
cat("Prompts loaded from:", PROMPTS_FILE, "\n")

benchmark_questions <- list(
  # ── SIMPLE (16) ──────────────────────────────────────────────
  list(id="S01", category="simple",
       question="How many variants in SOD1 have a PolyPhen score of D (damaging)?"),
  list(id="S02", category="simple",
       question="List all unique chromosomes present in the varInfo_synthetic table."),
  list(id="S03", category="simple",
       question="How many variants have a CADD score above 30 and are in the gene ABCA4?"),
  list(id="S04", category="simple",
       question="How many synonymous variants are there in the entire dataset?"),
  list(id="S05", category="simple",
       question="How many variants are present in the gene OPTN?"),
  list(id="S06", category="simple",
       question="How many high-impact variants are located on chromosome X?"),
  list(id="S07", category="simple",
       question="How many variants are predicted deleterious by both SIFT and PolyPhen simultaneously?"),
  list(id="S08", category="simple",
       question="How many variants is ALS_2 homozygous for?"),
  list(id="S09", category="simple",
       question="How many distinct genes are present in the varInfo_synthetic table?"),
  list(id="S10", category="simple",
       question="How many variants are in the dataset in total?"),
  list(id="S11", category="simple",
       question="How many variants does each gene have? Order by most variants."),
  list(id="S12", category="simple",
       question="How many variants have a missing CADD score?"),
  list(id="S13", category="simple",
       question="How many variants have all three annotations available: CADD, PolyPhen, and SIFT?"),
  list(id="S14", category="simple",
       question="How many high-impact variants are in ABCA4?"),
  list(id="S15", category="simple",
       question="How many variants have an allele frequency of exactly zero?"),
  list(id="S16", category="simple",
       question="How many variants does SIFT predict as deleterious in OPTN?"),

  # ── ANALYTICAL (17) ──────────────────────────────────────────
  list(id="A01", category="analytical",
       question="Which variant in NEK1 has the lowest non-zero allele frequency?"),
  list(id="A02", category="analytical",
       question="What proportion of all variants in the dataset are classified as high impact?"),
  list(id="A03", category="analytical",
       question="For each gene, what is the ratio of high-impact to synonymous variants? Only show genes with at least 5 of each."),
  list(id="A04", category="analytical",
       question="Which control sample carries the highest total burden of high-impact variants?"),
  list(id="A05", category="analytical",
       question="What is the average CADD score for variants predicted deleterious by both SIFT and PolyPhen, compared to variants predicted benign by both?"),
  list(id="A06", category="analytical",
       question="What is the average allele frequency per chromosome? Which chromosome has the highest?"),
  list(id="A07", category="analytical",
       question="What is the total allele burden in SOD1 for ALS cases versus controls?"),
  list(id="A08", category="analytical",
       question="What percentage of all variants in the dataset is carried by at least one ALS patient?"),
  list(id="A09", category="analytical",
       question="What is the average CADD score for high-impact versus moderate-impact variants in NEK1?"),
  list(id="A10", category="analytical",
       question="How many variants are carried exclusively by controls and not by any ALS patient?"),
  list(id="A11", category="analytical",
       question="What is the impact distribution (high, moderate, synonymous) in SOD1?"),
  list(id="A12", category="analytical",
       question="Which chromosome has the most variants in the dataset?"),
  list(id="A13", category="analytical",
       question="What percentage of variants are missing ALL three functional annotations: CADD, PolyPhen, and SIFT?"),
  list(id="A14", category="analytical",
       question="For ALS_4, how many high-impact variants are heterozygous versus homozygous?"),
  list(id="A15", category="analytical",
       question="What is the average CADD score of moderate-impact variants in PEX5?"),
  list(id="A16", category="analytical",
       question="What is the allele burden for ALS_5 versus Control_5 among high-impact variants only?"),
  list(id="A17", category="analytical",
       question="Give a full summary of the gene UBQLN2: total variants, impact distribution, and mean allele frequency."),

  # ── COMPLEX (18) ─────────────────────────────────────────────
  list(id="C01", category="complex",
       question="How many variants are carried exclusively by ALS cases and not by any control?"),
  list(id="C02", category="complex",
       question="Which gene shows the greatest difference in total allele burden between ALS cases and controls?"),
  list(id="C03", category="complex",
       question="For each of the five ALS patients, how many high-impact variants do they carry in TARDBP, SOD1, or NEK1?"),
  list(id="C04", category="complex",
       question="Which gene has the most homozygous variant-calls across all ALS patients combined?"),
  list(id="C05", category="complex",
       question="How many variants are shared between all five ALS patients AND all five controls?"),
  list(id="C06", category="complex",
       question="For moderate- and high-impact variants in TARDBP, compare the allele burden per individual across all 5 cases and all 5 controls."),
  list(id="C07", category="complex",
       question="Which variants are present in all ten individuals (all 5 ALS and all 5 controls)? List gene and VAR_id."),
  list(id="C08", category="complex",
       question="Among SIFT-deleterious variants, which three genes have the highest total case burden, and how does it compare to controls?"),
  list(id="C09", category="complex",
       question="How many variants fall into each impact category: high, moderate, synonymous, and other?"),
  list(id="C10", category="complex",
       question="In which genes does ALS_3 carry at least one high-impact variant?"),
  list(id="C11", category="complex",
       question="Give a full summary of the gene FUS: total variants, impact distribution, and mean allele frequency."),
  list(id="C12", category="complex",
       question="Group all variants by CADD score bins: below 10, 10 to 20, 20 to 30, and 30 and above. For each bin show the total ALS case burden and number of variants."),
  list(id="C13", category="complex",
       question="Among high-impact variants, what is the distribution of PolyPhen predictions?"),
  list(id="C14", category="complex",
       question="What are the three variants with the highest CADD score in the entire dataset, and which genes are they in?"),
  list(id="C15", category="complex",
       question="What are the three variants with the lowest non-zero allele frequency, and which genes are they in?"),
  list(id="C16", category="complex",
       question="What is the only high-impact variant in FUS, and what are its functional annotations?"),
  list(id="C17", category="complex",
       question="On which chromosome is IL3RA located, and how does the variant count on that chromosome compare to the total dataset?"),
  list(id="C18", category="complex",
       question="For RIN3 high-impact variants specifically, is the allele burden higher in cases or controls?"),

  # ── PHENOTYPE (6) ────────────────────────────────────────────
  list(id="P01", category="phenotype",
       question="How many female carriers are there in ABCA4?"),
  list(id="P02", category="phenotype",
       question="How many female carriers are there in SOD1?"),
  list(id="P03", category="phenotype",
       question="How many SAS carriers are there in NEK1?"),
  list(id="P04", category="phenotype",
       question="What is the sex distribution of samples in the database?"),
  list(id="P05", category="phenotype",
       question="What is the average age of ALS cases in the database?"),
  list(id="P06", category="phenotype",
       question="How many ALS cases and controls are in the database?"),

  # ── ANNOTATION TRAPS (3) ─────────────────────────────────────
  list(id="T01", category="annotation_trap",
       question="How many variants have a PolyPhen score of possibly damaging?"),
  list(id="T02", category="annotation_trap",
       question="How many variants are tolerated by SIFT?"),
  list(id="T03", category="annotation_trap",
       question="Are there any variants where HighImpact equals 1 AND Synonymous equals 1 at the same time?"),

  # ── UNANSWERABLE (15) ────────────────────────────────────────
  list(id="U01", category="unanswerable",
       question="Is VAR_id 100 previously reported as pathogenic?"),
  list(id="U02", category="unanswerable",
       question="What is the allele frequency of VAR_id 30 in Europeans?"),
  list(id="U03", category="unanswerable",
       question="Which variants are both synonymous and high impact?"),
  list(id="U04", category="unanswerable",
       question="What is the protein domain affected by VAR_id 42?"),
  list(id="U05", category="unanswerable",
       question="Has the variant at position 12345 been validated in a wet-lab experiment?"),
  list(id="U06", category="unanswerable",
       question="Which ALS patient has the earliest age of onset?"),
  list(id="U07", category="unanswerable",
       question="What is the linkage disequilibrium between VAR_id 10 and VAR_id 11?"),
  list(id="U08", category="unanswerable",
       question="Which variants are clinically significant?"),
  list(id="U09", category="unanswerable",
       question="What is the rs-number of VAR_id 200?"),
  list(id="U10", category="unanswerable",
       question="Which variants are de novo mutations?"),
  list(id="U11", category="unanswerable",
       question="What is the allele frequency of VAR_id 50 in the African population?"),
  list(id="U12", category="unanswerable",
       question="How long has ALS_3 been diagnosed with ALS?"),
  list(id="U13", category="unanswerable",
       question="Which variants have the strongest effect on disease risk?"),
  list(id="U14", category="unanswerable",
       question="Which of the ALS patients has the most severe disease progression?"),
  list(id="U15", category="unanswerable",
       question="Is the variant at position 1378764 on chrX likely to be causative for ALS?"),

  # ── RVAT (5) ─────────────────────────────────────────────────
  list(id="R01", category="rvat",
       question="Run a burden test for SOD1 in ALS cases versus controls."),
  list(id="R02", category="rvat",
       question="Get the MAF for moderate impact variants in TARDBP."),
  list(id="R03", category="rvat",
       question="How many female carriers are there in the SAS cohort that carry a pathogenic mutation in SOD1?"),
  list(id="R04", category="rvat",
       question="What is the linkage disequilibrium between high-impact variants in FUS?"),
  list(id="R05", category="rvat",
       question="What are the most significant single variants in NEK1 associated with ALS?"),

  # ── NONSENSE (16) ────────────────────────────────────────────
  ## Category 1: Missing annotation (N01-N05)
  list(id="N01", category="nonsense",
       question="What is the ClinVar pathogenicity classification of VAR_id 42?"),
  list(id="N02", category="nonsense",
       question="What is the gnomAD allele frequency of the variant at position 1378764 on chrX in the European population?"),
  list(id="N03", category="nonsense",
       question="Which exon does the high-impact variant in FUS (VAR_id 1175) affect?"),
  list(id="N04", category="nonsense",
       question="What is the protein domain affected by the most deleterious variant in SOD1?"),
  list(id="N05", category="nonsense",
       question="Does VAR_id 200 affect splicing?"),
  ## Category 2: Biologically or logically impossible (N06-N10)
  list(id="N06", category="nonsense",
       question="Which variants are both synonymous and high impact?"),
  list(id="N07", category="nonsense",
       question="Which variants have a genotype of 3 (i.e. three copies of the alternate allele) in ALS_1?"),
  list(id="N08", category="nonsense",
       question="What is the allele frequency of a variant that no one in the world carries?"),
  list(id="N09", category="nonsense",
       question="How many variants have a CADD score of exactly 0 and are also high impact?"),
  list(id="N10", category="nonsense",
       question="Which ALS patient is also listed as a control?"),
  ## Category 3: Too vague to answer (N11-N15)
  list(id="N11", category="nonsense",
       question="Which variants are important?"),
  list(id="N12", category="nonsense",
       question="Is NEK1 an ALS gene?"),
  list(id="N13", category="nonsense",
       question="What is the most interesting variant in the dataset?"),
  list(id="N14", category="nonsense",
       question="Which variants should we follow up on in the wet lab?"),
  list(id="N15", category="nonsense",
       question="Is this dataset good enough to find the cause of ALS?"),
  ## Category 4: Pure nonsense / gibberish (N16)
  list(id="N16", category="nonsense",
       question="jasdkjahdkjahdas"),

  # ── TOOLFREE (15) ────────────────────────────────────────────
  ## Variant-level SQL (F01-F10)
  list(id="F01", category="toolfree",
       question="For how many variants is the total allele count higher in ALS cases than in controls?"),
  list(id="F02", category="toolfree",
       question="Which gene has the highest proportion of high-impact variants relative to its total variant count?"),
  list(id="F03", category="toolfree",
       question="How many variants are carried (het or hom) by at least 3 of the 5 ALS patients?"),
  list(id="F04", category="toolfree",
       question="What is the average CADD score of high-impact variants per chromosome? Which chromosome has the highest average CADD score among high-impact variants?"),
  list(id="F05", category="toolfree",
       question="What is the total number of alleles carried by each individual ALS patient across all variants in the dataset?"),
  list(id="F06", category="toolfree",
       question="How many variants are homozygous (genotype = 2) in ALL five ALS patients simultaneously?"),
  list(id="F07", category="toolfree",
       question="Does a higher CADD score correlate with a higher rate of PolyPhen 'damaging' (D) predictions? Show this using CADD bins."),
  list(id="F08", category="toolfree",
       question="How many variants are carried by exactly one ALS patient and by no control at all (so-called 'private' ALS variants)?"),
  list(id="F09", category="toolfree",
       question="Which ALS patient has the most 'private' variants — variants carried only by that patient and no one else in the entire dataset?"),
  list(id="F10", category="toolfree",
       question="For high-impact variants only, what is the case-to-control burden ratio per gene? Which genes show enrichment in cases?"),
  ## Pheno table queries (F11-F13)
  list(id="F11", category="toolfree",
       question="What is the mean age of ALS cases per super-population? Which population has the highest average age?"),
  list(id="F12", category="toolfree",
       question="How many female ALS cases are there in the South Asian (SAS) population?"),
  list(id="F13", category="toolfree",
       question="What is the sex, population, and age of each of the five named ALS patients (ALS1 through ALS5) from the pheno table?"),
  ## Edge cases (F14-F15)
  list(id="F14", category="toolfree",
       question="How many variants have contradictory functional predictions — deleterious by SIFT but benign by PolyPhen? Which genes have the most such contradictory variants?"),
  list(id="F15", category="toolfree",
       question="How many variants have an allele frequency above the dataset average? Use a subquery to compute the average.")
)

cat("Total questions:", length(benchmark_questions), "\n")  ## should be 111

## ── Setup / ask wrappers ─────────────────────────────────────
setup_session  <- function(model_name) agentic_setup(model_name)
ask_question   <- function(session, question) agentic_ask(session, question)

## ── Run benchmark ─────────────────────────────────────────────
run_benchmark <- function(model_name, questions) {
  cat("\n========================================\n")
  cat("Backend:", BACKEND, "| Model:", model_name, "\n")
  cat("========================================\n")
  session <- setup_session(model_name)
  if (is.null(session)) { cat("Skipping", model_name, "- setup failed\n"); return(NULL) }
  results <- list()
  for (i in seq_along(questions)) {
    q <- questions[[i]]
    cat(sprintf("  [%d/%d] %s\n", i, length(questions), q$id))
    t_start     <- proc.time()[["elapsed"]]
    out         <- ask_question(session, q$question)
    elapsed_sec <- round(proc.time()[["elapsed"]] - t_start, 1)
    elapsed_fmt <- if (elapsed_sec >= 60) {
      sprintf("%d:%02d min", as.integer(elapsed_sec) %/% 60L,
              as.integer(elapsed_sec) %% 60L)
    } else {
      sprintf("%.1f sec", elapsed_sec)
    }
    cat(sprintf("         \u21b3 %.1f sec\n", elapsed_sec))
    ## Flatten phase timing into named columns (decompose_sec, route_sec, etc.)
    ## so they show up directly in the combined CSV for analysis/plotting.
    pt <- out$phase_timing
    phase_cols <- if (!is.null(pt)) {
      nm <- names(pt)
      vals <- sapply(pt, function(x) if (is.null(x)) NA_real_ else as.numeric(x))
      setNames(as.list(vals), paste0("phase_", nm, "_sec"))
    } else list()
    results[[q$id]] <- c(list(
      id=q$id, category=q$category, question=q$question,
      full=out$full, response=out$response,
      model=model_name, backend=BACKEND,
      elapsed_sec=elapsed_sec, elapsed_fmt=elapsed_fmt
    ), phase_cols)
    Sys.sleep(2)
  }
  results
}

## ── Output ────────────────────────────────────────────────────
BENCHMARK_TIMESTAMP <- format(Sys.time(), "%Y%m%d_%H%M%S")
output_dir <- path.expand(file.path(
  BENCHMARK_DIR,
  paste0("benchmark_", BACKEND, "_", BENCHMARK_TIMESTAMP)
))
dir.create(output_dir, recursive=TRUE)
cat("Output folder:", output_dir, "\n")

all_results_list <- list()

models_for_this_backend <- if (BACKEND == "agentic_dual") {
  pairs <- expand.grid(orch=ORCH_MODELS_TO_TEST, sub=SUB_MODELS_TO_TEST,
                       stringsAsFactors=FALSE)
  paste0(pairs$orch, " -> ", pairs$sub)
} else if (BACKEND == "agentic_adaptive") {
  ## Adaptive: LLM1 picks between sub_sql and sub_reason automatically
  paste0(ORCH_MODELS_TO_TEST, " [adaptive]")
} else { MODELS_TO_TEST }

for (model_name in models_for_this_backend) {
  results <- run_benchmark(model_name, benchmark_questions)
  if (is.null(results)) next
  model_clean <- gsub("[^a-zA-Z0-9_]", "_", model_name)
  output <- c("BENCHMARK RESULTS",
              paste("Backend:", BACKEND), paste("Model:  ", model_name),
              paste("Date:   ", format(Sys.time(), "%Y-%m-%d %H:%M:%S")),
              "================================================", "")
  for (r in results) {
    output <- c(output,
                paste("ID:      ", r$id), paste("Category:", r$category),
                paste("Question:", r$question),
                paste("Time:    ", r$elapsed_fmt),
                "--- Full output ---", r$full,
                "--- Final response ---", r$response,
                "------------------------------------------------", "")
  }
  writeLines(output, file.path(output_dir, paste0(model_clean, ".txt")))
  for (r in results) {
    ## Build each row as a single-row data.frame so phase_* columns (which
    ## vary per-question depending on which phases fired) line up by name
    ## rather than position. Missing phase columns become NA automatically.
    row_df <- as.data.frame(c(
      list(id=r$id, category=r$category, question=r$question,
           full=r$full, response=r$response,
           model=model_name, backend=BACKEND,
           elapsed_sec=r$elapsed_sec, elapsed_fmt=r$elapsed_fmt),
      r[grepl("^phase_", names(r))]
    ), stringsAsFactors = FALSE)
    all_results_list[[length(all_results_list) + 1]] <- row_df
  }
}

## Combine all rows — fills missing phase_* columns with NA where a
## particular question/backend never triggered that phase.
all_columns <- unique(unlist(lapply(all_results_list, names)))
all_results <- do.call(rbind, lapply(all_results_list, function(df) {
  missing <- setdiff(all_columns, names(df))
  for (m in missing) df[[m]] <- NA
  df[all_columns]
}))
if (is.null(all_results)) {
  all_results <- data.frame(
    id=character(), category=character(), question=character(),
    full=character(), response=character(),
    model=character(), backend=character(),
    elapsed_sec=numeric(), elapsed_fmt=character(),
    stringsAsFactors=FALSE
  )
}

BENCHMARK_CSV <- file.path(output_dir, "all_backends_combined.csv")
write.csv(all_results, BENCHMARK_CSV, row.names=FALSE)
cat("Combined CSV saved:", BENCHMARK_CSV, "\n")
cat("Benchmark complete! Results in:", output_dir, "\n")