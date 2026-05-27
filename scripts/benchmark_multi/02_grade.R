## ============================================================
## 02_grade.R
## Auto-grade benchmark results, then prompt for manual review
## of any rows the LLM judge could not parse.
## ============================================================

library(ollamar)
library(jsonlite)
library(ellmer)
library(rollama)

## ── Resolve the CSV to grade ──────────────────────────────────
## When sourced from run_pipeline.R, BENCHMARK_CSV is already set
## by 01_benchmark.R. When run standalone, set it manually below.
if (!exists("BENCHMARK_CSV")) {
  BENCHMARK_CSV <- "~/project_ALS_databse/analysis/benchmark_testing/benchmark_20260511_093437/all_models_combined.csv"
}

## ── Resolve paths from config ─────────────────────────────────
if (!exists("BENCHMARKS_MD")) {
  source(file.path(dirname(sys.frame(1)$ofile), "config.R"))
}

benchmark_content <- paste(readLines(path.expand(BENCHMARKS_MD)), collapse = "\n")

## ── Timestamped grading subdirectory ─────────────────────────
grading_run_timestamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
grading_run_dir <- file.path(
  path.expand(GRADING_DIR),
  paste0("grading_", grading_run_timestamp)
)
dir.create(grading_run_dir, recursive = TRUE, showWarnings = FALSE)
cat("Grading output folder:", grading_run_dir, "\n")

## ── Derive timestamp for filenames from the benchmark CSV ─────
benchmark_timestamp <- regmatches(
  BENCHMARK_CSV,
  regexpr("[0-9]{8}_[0-9]{6}", BENCHMARK_CSV)
)

## ============================================================
## STEP 1: Auto-grade with LLM
## ============================================================

auto_grade_ollama <- function(csv_path, outfile_name, judge_model = JUDGE_MODEL) {
  
  outfile_path <- file.path(grading_run_dir, outfile_name)
  file <- read.csv(csv_path)
  
  file$grade_answer           <- NA
  file$grade_minimal_response <- NA
  file$grade_hallucination    <- NA
  file$grade_sql              <- NA
  file$grade_total            <- NA
  file$grade_reasoning        <- NA
  
  rubric <- paste0(
    "You are grading a genomics chatbot's responses to questions about an ALS variant database.
Genotype values (0,1,2) indicate zygosity only, NOT disease association.
Missing values are stored as '.' not NULL.
PolyPhen and SIFT are computational predictions only, NOT evidence of pathogenicity.
A variant cannot be both Synonymous and HighImpact simultaneously.

Below is the full benchmark document containing the expected SQL queries and correct answers
for each question. Use this as your ground truth when grading:

================================================================
", benchmark_content, "
================================================================

Grade the response on 4 criteria, each true or false:

1. grade_answer: Is the final answer correct or appropriate?
   - Compare against the expected answer in the benchmark document above
   - For unanswerable questions: did it correctly refuse and explain why?
   - For expert questions (E1-E3): accept any reasonable interpretation as long as
     the model states which interpretation it uses and the answer matches that
     interpretation. E1 has two valid interpretations (variant count OR burden).
     Either is acceptable if clearly stated.
   - For rvat questions (R1-R5): these require multi-table access (pheno, SM tables)
     or rvat functions. Accept any approach that produces a correct answer:
     SQL joins, rvat R code, or MCP multi-table tools.
     If the backend cannot answer (e.g. querychat locked to varInfo_synthetic),
     a correct refusal explaining the limitation scores TRUE for grade_answer.
     grade_sql should be TRUE if the SQL/code logic is sound, even if the exact
     syntax differs between rvat and SQL approaches.

2. grade_minimal_response: Is the response concise (1-3 sentences)?
   - true if brief and to the point
   - false if overly verbose, lists individual rows, or rambles

3. grade_hallucination: Is the response free of hallucinations?
   - true if no invented data, column names, or biological misinterpretations
   - false if it invents values, misinterprets genotypes as disease association,
     or claims pathogenicity from PolyPhen/SIFT alone

4. grade_sql: Is the SQL query correct?
   - Compare against the expected SQL in the benchmark document above
   - true if the SQL logic is sound and would return the right data
   - false if wrong columns, wrong logic, or no SQL when one was needed
   - true if question is unanswerable and no SQL was correctly not generated

You MUST respond with ONLY a JSON object. No preamble. No explanation. No markdown.
Start your response with { and end with }.
Example of the exact format required:
{grade_answer: true, grade_minimal_response: true, grade_hallucination: true, grade_sql: true, reasoning: the answer is correct}

The keys must be exactly: grade_answer, grade_minimal_response, grade_hallucination, grade_sql, reasoning"
  )
  
  for (row in 1:nrow(file)) {
    cat("Grading row", row, "/", nrow(file), "-", file$id[row], "-", file$model[row], "\n")
    
    prompt <- paste0(
      "Question category: ", file$category[row], "\n",
      "Question: ", file$question[row], "\n\n",
      "Full output (including SQL):\n", file$full[row], "\n\n",
      "Final response:\n", file$response[row]
    )
    
    result <- tryCatch({
      resp <- ollamar::chat(
        model    = judge_model,
        messages = list(
          list(role = "system", content = rubric),
          list(role = "user",   content = prompt)
        ),
        format      = "json",
        output      = "text",
        num_predict = 400,
        temperature = 0
      )
      
      ## ── Robust JSON extraction ───────────────────────────
      ## Find the first { and last } to extract the JSON block,
      ## ignoring any preamble gemma3 adds before the JSON.
      start <- regexpr("\\{", resp)[[1]]
      end   <- tail(gregexpr("\\}", resp)[[1]], 1)
      
      if (start == -1 || end == -1 || end < start) {
        stop("No JSON object found in response")
      }
      
      json_str <- substr(resp, start, end)
      jsonlite::fromJSON(json_str)
      
    }, error = function(e) {
      cat("  PARSE ERROR on row", row, ":", conditionMessage(e), "\n")
      NULL
    })
    
    if (!is.null(result)) {
      file$grade_answer[row]           <- isTRUE(result$grade_answer)
      file$grade_minimal_response[row] <- isTRUE(result$grade_minimal_response)
      file$grade_hallucination[row]    <- isTRUE(result$grade_hallucination)
      file$grade_sql[row]              <- isTRUE(result$grade_sql)
      file$grade_reasoning[row]        <- ifelse(
        is.null(result$reasoning), "No reasoning provided", as.character(result$reasoning)
      )
      file$grade_total[row] <- sum(
        isTRUE(result$grade_answer),
        isTRUE(result$grade_minimal_response),
        isTRUE(result$grade_hallucination),
        isTRUE(result$grade_sql)
      )
    }
    
    Sys.sleep(1)
  }
  
  mean_grade <- round(mean(file$grade_total, na.rm = TRUE), digits = 1)
  cat("*******************************************\n")
  cat("Auto-grading done!\n")
  cat("Average score so far: (", mean_grade, "/4)\n", sep = "")
  cat("*******************************************\n")
  
  out_csv <- paste0(outfile_path, ".csv")
  write.csv(file, out_csv, row.names = FALSE)
  cat("Auto-graded file saved to:", out_csv, "\n")
  return(out_csv)
}

## ============================================================
## STEP 2: Manual review of NA rows
## ============================================================

manual_review <- function(graded_csv, outfile_name) {
  
  outfile_path <- file.path(grading_run_dir, outfile_name)
  file <- read.csv(graded_csv)
  
  na_rows <- which(
    is.na(file$grade_answer) |
      is.na(file$grade_minimal_response) |
      is.na(file$grade_hallucination) |
      is.na(file$grade_sql)
  )
  
  cat("Found", length(na_rows), "rows needing manual review\n\n")
  
  if (length(na_rows) == 0) {
    cat("No manual review needed!\n")
  } else {
    for (row in na_rows) {
      cat("======================================================================\n")
      cat("(", which(na_rows == row), "/", length(na_rows), ")\n", sep = "")
      cat("ID:", file$id[row], "| Model:", file$model[row], "\n")
      cat("Category:", file$category[row], "\n")
      cat("Question:", file$question[row], "\n\n")
      cat("--- Full output (incl. SQL) ---\n")
      cat(file$full[row], "\n\n")
      cat("--- Final response ---\n")
      cat(file$response[row], "\n")
      cat("--- Auto-grade reasoning ---\n")
      cat(ifelse(is.na(file$grade_reasoning[row]), "No reasoning provided", file$grade_reasoning[row]), "\n")
      cat("======================================================================\n")
      
      file$grade_answer[row]           <- toupper(readline("Answer correct? (T/F): ")) == "T"
      file$grade_minimal_response[row] <- toupper(readline("Minimal response? (T/F): ")) == "T"
      file$grade_hallucination[row]    <- toupper(readline("Hallucination free? (T/F): ")) == "T"
      file$grade_sql[row]              <- toupper(readline("SQL correct? (T/F): ")) == "T"
      file$grade_total[row]            <- sum(
        file$grade_answer[row],
        file$grade_minimal_response[row],
        file$grade_hallucination[row],
        file$grade_sql[row]
      )
    }
  }
  
  mean_grade <- round(mean(file$grade_total, na.rm = TRUE), digits = 1)
  cat("*******************************************\n")
  cat("All done!\n")
  cat("Final average score: (", mean_grade, "/4)\n", sep = "")
  cat("*******************************************\n")
  
  out_csv <- paste0(outfile_path, ".csv")
  write.csv(file, out_csv, row.names = FALSE)
  cat("Final graded file saved to:", out_csv, "\n")
  
  ## Expose path for downstream scripts
  GRADED_FINAL_CSV <<- out_csv
}

## ── Run ───────────────────────────────────────────────────────
autograded_file <- auto_grade_ollama(
  csv_path     = path.expand(BENCHMARK_CSV),
  outfile_name = paste0("autograded_", benchmark_timestamp)
)

## Skip manual review when non-interactive (e.g. Rscript from terminal).
## NA rows will remain in the autograded CSV.
## Run manual_review.R separately in RStudio to grade them interactively.
if (interactive()) {
  manual_review(
    graded_csv   = autograded_file,
    outfile_name = paste0("finalgraded_", benchmark_timestamp)
  )
} else {
  cat("Non-interactive session detected — skipping manual review.\n")
  cat("NA rows saved in:", autograded_file, "\n")
  cat("Run manual_review.R in RStudio to complete grading.\n")
  ## Copy autograded as finalgraded so downstream steps still work
  GRADED_FINAL_CSV <<- sub("autograded_", "finalgraded_", autograded_file)
  file.copy(autograded_file, GRADED_FINAL_CSV, overwrite = TRUE)
  cat("Copied to:", GRADED_FINAL_CSV, "\n")
}
