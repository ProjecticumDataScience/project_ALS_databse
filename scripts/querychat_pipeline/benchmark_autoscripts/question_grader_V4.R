library(ellmer)
library(rollama)
library(ollamar)
library(jsonlite)

## Set these before running
csv_to_grade <- "~/project_ALS_databse/analysis/benchmark_testing/benchmark_20260510_141103/all_models_combined.csv"

benchmark_timestamp <- regmatches(
  csv_to_grade,
  regexpr("[0-9]{8}_[0-9]{6}", csv_to_grade)
)

## Grader function
auto_grade_ollama <- function(csv_path, outfile_name, judge_model = "gemma3") {
  
  grading_dir <- path.expand("~/project_ALS_databse/analysis/benchmark_grading")
  dir.create(grading_dir, recursive = TRUE, showWarnings = FALSE)
  outfile_path <- file.path(grading_dir, outfile_name)
  
  file <- read.csv(csv_path)
  file$grade_answer           <- NA
  file$grade_minimal_response <- NA
  file$grade_hallucination    <- NA
  file$grade_sql              <- NA
  file$grade_total            <- NA
  file$grade_reasoning        <- NA
  
  rubric <- "You are grading a genomics chatbot's responses to questions about an ALS variant database.
The database contains variant data with columns: VAR_id, CHROM, POS, gene_name, HighImpact,
ModerateImpact, Synonymous, CADDphred, PolyPhen, SIFT, ALS_1-ALS_5, Control_1-Control_5.
Genotype values (0,1,2) indicate zygosity only, NOT disease association.
Missing values are stored as '.' not NULL.

Grade the response on 4 criteria, each true or false:

1. grade_answer: Is the final answer correct or appropriate?
   - For lookup/analytical questions: did it get the right result?
   - For unanswerable questions: did it correctly refuse and explain why?

2. grade_minimal_response: Is the response concise (1-3 sentences)?
   - true if brief and to the point
   - false if overly verbose, lists rows, or rambles

3. grade_hallucination: Is the response free of hallucinations?
   - true if no invented data, column names, or biological misinterpretations
   - false if it invents values, misinterprets genotypes as disease association,
     or claims pathogenicity from PolyPhen/SIFT alone

4. grade_sql: Is the SQL query correct?
   - true if the SQL logic is sound and would return the right data
   - false if wrong columns, wrong logic, or no SQL when one was needed
   - true if question is unanswerable and no SQL was correctly not generated

Return a JSON object with exactly these keys:
grade_answer, grade_minimal_response, grade_hallucination, grade_sql, reasoning"
  
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
        format  = "json",
        output  = "text",
        num_predict = 300,
        temperature = 0
      )
      clean <- gsub("```json|```", "", resp)
      clean <- trimws(clean)
      # try to extract JSON if surrounded by text
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
      file$grade_reasoning[row]        <- result$reasoning
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
  cat("Done!\n")
  cat("Average score: (", mean_grade, "/4)\n", sep = "")
  cat("*******************************************\n")
  
  write.csv(file, paste0(outfile_path, ".csv"), row.names = FALSE)
  cat("Graded file saved to:", paste0(outfile_path, ".csv"), "\n")
}

## Run the grader
auto_grade_ollama(
  csv_path     = path.expand(csv_to_grade),
  outfile_name = paste0("autograded_", benchmark_timestamp),
  judge_model  = "gemma3"
)