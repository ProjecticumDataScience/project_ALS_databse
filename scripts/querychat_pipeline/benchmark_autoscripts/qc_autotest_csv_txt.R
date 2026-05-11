library(ellmer)
library(querychat)
library(rollama)
library(DBI)
library(rvat)
library(rvatData)
library(R.utils)
library(here)

## Setup
gdb <- gdb(rvat_example("rvatData.gdb"))
vi <- dbGetQuery(gdb, "SELECT * FROM varInfo")
set.seed(123)
n_rows <- nrow(vi)
geno_als <- replicate(5, sample(0:2, n_rows, replace = TRUE))
colnames(geno_als) <- paste0("ALS_", 1:5)
geno_control <- replicate(5, sample(0:2, n_rows, replace = TRUE))
colnames(geno_control) <- paste0("Control_", 1:5)
vi_updated <- cbind(vi, geno_als, geno_control)
dbWriteTable(gdb, "varInfo_synthetic", vi_updated, overwrite = TRUE)

## Data description
data_description <- "
Genomic variant data from Project MinE ALS study.
Each row is one variant; columns:
- VAR_id, CHROM, POS: variant ID, chromosome, genomic position
- ID, REF, ALT: rsID (if any), reference and alternative alleles
- AC, AN, AF: allele count, total alleles, allele frequency
- gene_name: gene where the variant falls
- HighImpact = 1 if high impact (e.g. stop-gain, frameshift); 0 otherwise
- ModerateImpact = 1 if moderate impact (e.g. missense); 0 otherwise
- Synonymous = 1 if synonymous (silent); 0 otherwise
- CADDphred: CADD phred score; higher = more deleterious; missing = '.'
- PolyPhen: 'D'=probably damaging, 'P'=possibly damaging, 'B'=benign; missing = '.'
- SIFT: 'D'=deleterious, 'T'=tolerated; missing = '.'
- ALS_1 to ALS_5: genotype of 5 ALS patients (0=ref/ref, 1=heterozygous, 2=hom/alt)
- Control_1 to Control_5: genotype of 5 controls (same encoding)
Important:
- A variant cannot be both Synonymous and HighImpact at the same time.
- Missing values (CADDphred, PolyPhen, SIFT) are stored as '.', not NULL.
- CADDphred > 20 is generally considered deleterious.
- There is NO group/phenotype column; cases are ALS_1-ALS_5, controls are Control_1-Control_5.
- To compute burden, sum the genotype columns directly (e.g. SUM(ALS_1 + ALS_2 + ...)).
"

## Extra instructions
extra_instructions <- "
RESPONSE RULES:
- Always start with the direct answer (a number, value, or yes/no) and keep the answer to 1-3 sentences.
- Only use the columns and terms in the data_description above. Never invent or guess column names, gene names, or values.
- If a question cannot be answered from these columns, answer: 'This information is not available in the dataset.' and name the missing column.
- If a term like 'most deleterious' or 'important' is ambiguous, briefly say which metric you use before querying.
- Treat missing values (CADDphred, PolyPhen, SIFT) as '.' and filter with WHERE column != '.'.
- Genotype values 0, 1, 2 indicate zygosity only; never interpret them as disease association.
- If asked whether a variant is both synonymous and high impact, explain that these labels are mutually exclusive.
- Do not rewrite, rephrase, or speculate about the question; answer only what is asked.
- Before running a query, check if the question can be answered with available columns. If not, refuse immediately.
- PolyPhen and SIFT are computational predictions only, NOT evidence of pathogenicity.
EXAMPLES:
- Question: How many high-impact variants does the ALS_1 patient carry?
  Interpretation: count variants where HighImpact = 1 AND ALS_1 > 0.
- Question: Which variants are most important?
  Correct response: 'Important' is ambiguous. Do you mean highest CADDphred, HighImpact = 1, or highest case burden? Please clarify.
- Question: Is VAR_id 100 pathogenic?
  Correct response: This information is not available in the dataset. There is no pathogenicity annotation column.
"

## Benchmark questions
benchmark_questions <- list(
  list(id = "L1", category = "lookup",       question = "How many variants are in NEK1?"),
  list(id = "L2", category = "lookup",       question = "Select variants in NEK1 with HighImpact and a CADDphred > 20"),
  list(id = "L3", category = "lookup",       question = "How many variants in TARDBP are predicted deleterious by SIFT?"),
  list(id = "L4", category = "lookup",       question = "Which high-impact variants have at least one ALS patient that is homozygous for the variant?"),
  list(id = "L5", category = "lookup",       question = "What are the ten most deleterious variants in ABCA4?"),
  list(id = "A1", category = "analytical",   question = "What is the variant with the highest allele frequency?"),
  list(id = "A2", category = "analytical",   question = "What is the average allele frequency for synonymous, moderate, and high-impact variants separately?"),
  list(id = "A3", category = "analytical",   question = "How many high-impact variants does the ALS_1 patient carry?"),
  list(id = "A4", category = "analytical",   question = "What is the total burden of cases versus controls?"),
  list(id = "A5", category = "analytical",   question = "Are there more variants in cases than controls?"),
  list(id = "U1", category = "unanswerable", question = "What is the average age of ALS cases?"),
  list(id = "U2", category = "unanswerable", question = "What is the allele frequency of VAR_id 30 in Europeans?"),
  list(id = "U3", category = "unanswerable", question = "Which variants are both synonymous and high impact?"),
  list(id = "U4", category = "unanswerable", question = "Which variants are most important?"),
  list(id = "U5", category = "unanswerable", question = "Is VAR_id 100 previously reported as pathogenic?")
)

## Models to test
models_to_test <- c(
  "llama3.1:8b",
  "mistral",
  "deepseek-r1:8b",
  "qwen3:8b",
  "llama3.2"
)

## Convert results to CSV
results_to_csv <- function(results, model_name, output_dir) {
  model_name_clean <- gsub("[^a-zA-Z0-9_]", "_", model_name)
  
  df <- data.frame(
    id       = sapply(results, function(r) r$id),
    category = sapply(results, function(r) r$category),
    question = sapply(results, function(r) r$question),
    response = sapply(results, function(r) r$response),
    model    = model_name,
    stringsAsFactors = FALSE
  )
  
  csv_file <- file.path(output_dir, paste0(model_name_clean, ".csv"))
  write.csv(df, csv_file, row.names = FALSE)
  cat("CSV saved:", csv_file, "\n")
}

## Benchmark function
run_benchmark <- function(model_name, questions, gdb, data_description, extra_instructions) {
  cat("\n\n========================================\n")
  cat("Testing model:", model_name, "\n")
  cat("========================================\n")
  
  ollama_client <- tryCatch({
    chat_ollama(
      model = model_name,
      params = ellmer::params(temperature = 0.1, num_predict = 200)
    )
  }, error = function(e) {
    cat("ERROR: Could not load model", model_name, "-", e$message, "\n")
    return(NULL)
  })
  
  if (is.null(ollama_client)) return(NULL)
  
  qc <- QueryChat$new(
    data_source = gdb,
    table_name = "varInfo_synthetic",
    client = ollama_client,
    data_description = data_description,
    extra_instructions = extra_instructions,
    categorical_threshold = 50,
    greeting = "Welcome!"
  )
  
  client <- qc$client(tools = "query")
  results <- list()
  
  for (q in questions) {
    cat("  Running:", q$id, "-", q$question, "\n")
    
    response <- tryCatch({
      withTimeout(
        unclass(client$chat(q$question)),
        timeout = 90,
        onTimeout = "error"
      )
    }, error = function(e) {
      paste("TIMEOUT/ERROR:", e$message)
    })
    
    results[[q$id]] <- list(
      id       = q$id,
      category = q$category,
      question = q$question,
      response = response
    )
    
    Sys.sleep(3)
  }
  
  return(results)
}

## Grader function
question_grader <- function(answers, outfile_name) {
  file <- read.csv(answers)
  file$grade <- NA
  for (row in 1:nrow(file)) {
    cat("======================================================================\n")
    print(t(file[row, ]))
    cat("======================================================================\n")
    answer <- toupper(readline("Answer correct? (T/F): "))
    file$grade[row] <- answer == "T"
  }
  write.csv(file, paste0(outfile_name, ".csv"), row.names = FALSE)
  cat("Graded file saved to:", paste0(outfile_name, ".csv"), "\n")
}

## Create output folder
run_timestamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
output_dir <- path.expand(paste0("~/project_ALS_databse/analysis/benchmark_testing/benchmark_", run_timestamp))
dir.create(output_dir, recursive = TRUE)
cat("Output folder created:", output_dir, "\n")

## Run all models
for (model_name in models_to_test) {
  results <- run_benchmark(model_name, benchmark_questions, gdb, data_description, extra_instructions)
  
  if (is.null(results)) {
    cat("Skipping", model_name, "- failed to load\n")
    next
  }
  
  model_name_clean <- gsub("[^a-zA-Z0-9_]", "_", model_name)
  
  # save TXT
  output <- c()
  output <- c(output, "BENCHMARK RESULTS")
  output <- c(output, paste("Model:", model_name))
  output <- c(output, paste("Date:", format(Sys.time(), "%Y-%m-%d %H:%M:%S")))
  output <- c(output, "================================================")
  output <- c(output, "")
  for (r in results) {
    output <- c(output, paste("ID:      ", r$id))
    output <- c(output, paste("Category:", r$category))
    output <- c(output, paste("Question:", r$question))
    output <- c(output, paste("Response:", r$response))
    output <- c(output, "------------------------------------------------")
    output <- c(output, "")
  }
  txt_file <- file.path(output_dir, paste0(model_name_clean, ".txt"))
  writeLines(output, txt_file)
  cat("TXT saved:", txt_file, "\n")
  
  # save CSV
  results_to_csv(results, model_name, output_dir)
}

cat("\nAll benchmarks complete! Results saved to:", output_dir, "\n")
cat("\nTo grade results, run:\n")
cat('question_grader("path/to/model.csv", "path/to/graded_output")\n')