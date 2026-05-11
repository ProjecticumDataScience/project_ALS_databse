library(ollamar)
library(jsonlite)
library(ellmer)
library(rollama)

## Set your CSV path here
csv_to_grade <- "~/project_ALS_databse/analysis/benchmark_testing/benchmark_20260511_093437/all_models_combined.csv"

# read the benchmark file
benchmark_content <- paste(readLines("~/project_ALS_databse/references/benchmarks.md"), collapse = "\n")

## Extract timestamp from path automatically
benchmark_timestamp <- regmatches(
  csv_to_grade,
  regexpr("[0-9]{8}_[0-9]{6}", csv_to_grade)
)

## Grading directories
grading_dir <- path.expand("~/project_ALS_databse/analysis/benchmark_grading")
dir.create(grading_dir, recursive = TRUE, showWarnings = FALSE)

## ============================================================
## STEP 1: Auto-grade with LLM
## ============================================================

auto_grade_ollama <- function(csv_path, outfile_name, judge_model = "gemma3") {
  
  outfile_path <- file.path(grading_dir, outfile_name)
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

Return a JSON object with exactly these keys:
grade_answer, grade_minimal_response, grade_hallucination, grade_sql, reasoning"
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
        num_predict = 300,
        temperature = 0
      )
      clean <- gsub("```json|```", "", resp)
      clean <- trimws(clean)
      json_match <- regmatches(clean, regexpr("\\{.*\\}", clean, perl = TRUE))
      if (length(json_match) > 0) {
        jsonlite::fromJSON(json_match[[1]])
      } else {
        jsonlite::fromJSON(clean)
      }
    }, error = function(e) {
      cat("  PARSE ERROR on row", row, "- marking as NA, review manually\n")
      NULL
    })
    
    if (!is.null(result)) {
      file$grade_answer[row]           <- isTRUE(result$grade_answer)
      file$grade_minimal_response[row] <- isTRUE(result$grade_minimal_response)
      file$grade_hallucination[row]    <- isTRUE(result$grade_hallucination)
      file$grade_sql[row]              <- isTRUE(result$grade_sql)
      file$grade_reasoning[row] <- ifelse(
        is.null(result$reasoning), 
        "No reasoning provided", 
        as.character(result$reasoning)
      )
      file$grade_total[row]            <- sum(
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
  
  write.csv(file, paste0(outfile_path, ".csv"), row.names = FALSE)
  cat("Auto-graded file saved to:", paste0(outfile_path, ".csv"), "\n")
  
  return(paste0(outfile_path, ".csv"))
}

## ============================================================
## STEP 2: Manual review of NA rows
## ============================================================

manual_review <- function(graded_csv, outfile_name) {
  
  outfile_path <- file.path(grading_dir, outfile_name)
  file <- read.csv(graded_csv)
  
  na_rows <- which(is.na(file$grade_answer) |
                     is.na(file$grade_minimal_response) |
                     is.na(file$grade_hallucination) |
                     is.na(file$grade_sql))
  
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
  
  write.csv(file, paste0(outfile_path, ".csv"), row.names = FALSE)
  cat("Final graded file saved to:", paste0(outfile_path, ".csv"), "\n")
}

## ============================================================
## RUN
## ============================================================

# Step 1: auto-grade
autograded_file <- auto_grade_ollama(
  csv_path     = path.expand(csv_to_grade),
  outfile_name = paste0("autograded_", benchmark_timestamp),
  judge_model  = "gemma3"
)

# Step 2: manual review of NAs
manual_review(
  graded_csv   = autograded_file,
  outfile_name = paste0("finalgraded_", benchmark_timestamp)
)