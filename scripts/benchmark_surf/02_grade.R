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
  BENCHMARK_CSV <- NULL  ## set automatically by run_pipeline.R — override here if running standalone
}

## ── Resolve paths from config ─────────────────────────────────
if (!exists("BENCHMARKS_MD")) {
  cfg <- tryCatch(
    file.path(dirname(sys.frame(1)$ofile), "config.R"),
    error = function(e) file.path(getwd(), "config.R")
  )
  source(cfg)
}

benchmark_content <- paste(readLines(path.expand(BENCHMARKS_MD)), collapse = "\n")

## ── Parse benchmark markdown into a per-ID answer lookup ─────
## Extracts rows from pipe tables: | ID | Question | Answer | ...
parse_benchmark_answers <- function(md_text) {
  lines  <- strsplit(md_text, "\n")[[1]]
  lookup <- list()
  for (ln in lines) {
    ln <- trimws(ln)
    if (!startsWith(ln, "|")) next
    cols <- strsplit(ln, "|", fixed = TRUE)[[1]]
    cols <- trimws(cols[nchar(trimws(cols)) > 0])
    if (length(cols) < 3) next
    id  <- cols[1]
    ans <- cols[3]
    ## Skip header/separator rows
    if (grepl("^[-:]+$", ans) || ans == "Answer" || ans == "Expected answer") next
    if (grepl("^[A-Z][0-9]{2}$", id)) {
      lookup[[id]] <- ans
    }
  }
  lookup
}
ANSWER_LOOKUP <- parse_benchmark_answers(benchmark_content)
cat("Parsed", length(ANSWER_LOOKUP), "expected answers from benchmark markdown\n")

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
  file$grade_tool              <- NA
  file$grade_total            <- NA
  file$grade_reasoning        <- NA
  
  ## Short static rubric — no benchmark content embedded
  rubric <- paste0(
    "You are grading a genomics chatbot that queries an ALS variant database.\n",
    "Database facts:\n",
    "- Genotype values 0/1/2 = ref/het/hom, NOT disease association\n",
    "- Missing values stored as '.' not NULL\n",
    "- PolyPhen/SIFT are computational predictions, NOT clinical pathogenicity\n",
    "- A variant cannot be both Synonymous and HighImpact simultaneously\n\n",
    "Grade on exactly 4 criteria (true/false each):\n",
    "1. grade_answer: Does the answer match the expected answer provided?\n",
    "   - Unanswerable Qs: TRUE if model correctly refuses and explains why\n",
    "   - Nonsense Qs (N): TRUE if model refuses/explains impossibility or returns 0\n",
    "   - Toolfree Qs (F): TRUE if the number/result matches expected\n",
    "   - Accept approximate numbers for aggregations (within 5%)\n",
    "2. grade_minimal_response: Is the response 1-3 sentences, no fluff?\n",
    "   - FALSE if it mentions rows, query details, or analysis process\n",
    "   - FALSE if it adds unnecessary biological speculation\n",
    "3. grade_hallucination: Did the response avoid inventing data not present in the tool result?\n",
    "   - TRUE in almost all cases where the answer is correct or correctly refused\n",
    "   - TRUE if the response says this information is not available\n",
    "   - TRUE if numbers match or are close to the expected answer\n",
    "   - TRUE even if the answer is wrong due to wrong tool — that is grade_tool=FALSE, not hallucination\n",
    "   - FALSE ONLY if the response states a SPECIFIC number or fact that directly CONTRADICTS the tool result\n",
    "   - FALSE ONLY examples: says 5 carriers when tool returned 2, says chr1 when tool returned chrX\n",
    "   - Do NOT mark FALSE just because response is brief, used a tool, or you disagree with phrasing\n",
    "   - IMPORTANT: A correct refusal ('not available') is NEVER a hallucination — mark TRUE\n",
    "   - IMPORTANT: Saying 0 when the answer is biologically impossible is NOT a hallucination — mark TRUE\n",
    "4. grade_tool: Was the right tool called with correct logic?\n",
    "   - TRUE if SQL/tool logic would return the correct data\n",
    "   - TRUE if unanswerable and no tool correctly skipped\n\n",
    "Respond with ONLY a JSON object. No markdown. No preamble. Start with {\n",
    "Required keys: grade_answer, grade_minimal_response, grade_hallucination, grade_tool, reasoning\n",
    "Example: {\"grade_answer\": true, \"grade_minimal_response\": true, \"grade_hallucination\": true, \"grade_tool\": true, \"reasoning\": \"correct\"}\n",
    "SPECIAL CASES:\n",
    "- P01 (female carriers ABCA4): accept BOTH 2 (named ALS patients only) AND 5 (all female carriers in full dataset)\n",
    "- P02 (female carriers SOD1): accept BOTH 2 AND 5\n",
    "- P03 (SAS carriers NEK1): accept BOTH 2 AND 4\n",
    "- C02 (greatest burden difference): ABCA4 (diff=83) is correct — if model says PEX5 or TARDBP, grade_answer=FALSE\n",
    "- C13 (PolyPhen distribution high-impact): missing ('.') = 106 is a valid category — penalise if omitted\n"
  )
  
  for (row in 1:nrow(file)) {
    cat("Grading row", row, "/", nrow(file), "-", file$id[row], "-", file$model[row], "\n")
    
    prompt <- paste0(
      "Question category: ", file$category[row], "\n",
      "Question: ", file$question[row], "\n\n",
      "Full output (including SQL):\n", file$full[row], "\n\n",
      "Final response:\n", file$response[row]
    )
    
    ## ── Build per-question prompt with only the relevant answer ──
    expected_ans <- ANSWER_LOOKUP[[file$id[row]]]
    expected_str <- if (!is.null(expected_ans)) {
      paste0("Expected answer: ", expected_ans)
    } else {
      paste0("Category: ", file$category[row],
             " — use your knowledge of the database to assess correctness.")
    }
    
    prompt_full <- paste0(
      "Question ID: ", file$id[row], "\n",
      "Category: ", file$category[row], "\n",
      "Question: ", file$question[row], "\n",
      expected_str, "\n\n",
      "Chatbot full output (includes tool calls):\n", file$full[row], "\n\n",
      "Chatbot final response:\n", file$response[row]
    )
    
    result <- tryCatch({
      resp <- ollamar::chat(
        model    = judge_model,
        messages = list(
          list(role = "system", content = rubric),
          list(role = "user",   content = prompt_full)
        ),
        format      = "json",
        output      = "text",
        num_predict = 300,
        temperature = 0
      )
      resp <- trimws(gsub("```json|```", "", resp))
      start <- regexpr("\\{", resp)[[1]]
      end   <- tail(gregexpr("\\}", resp)[[1]], 1)
      if (start == -1L || end == -1L || end < start) stop("No JSON found")
      jsonlite::fromJSON(substr(resp, start, end))
    }, error = function(e) {
      cat("  PARSE ERROR on row", row, ":", conditionMessage(e), "\n")
      NULL
    })
    
    if (!is.null(result)) {
      file$grade_answer[row]           <- isTRUE(result$grade_answer)
      file$grade_minimal_response[row] <- isTRUE(result$grade_minimal_response)
      file$grade_hallucination[row]    <- isTRUE(result$grade_hallucination)
      file$grade_tool[row]              <- isTRUE(result$grade_tool)
      file$grade_reasoning[row]        <- ifelse(
        is.null(result$reasoning), "No reasoning provided", as.character(result$reasoning)
      )
      file$grade_total[row] <- sum(
        isTRUE(result$grade_answer),
        isTRUE(result$grade_minimal_response),
        isTRUE(result$grade_hallucination),
        isTRUE(result$grade_tool)
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
      is.na(file$grade_tool)
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
      file$grade_tool[row]              <- toupper(readline("SQL correct? (T/F): ")) == "T"
      file$grade_total[row]            <- sum(
        file$grade_answer[row],
        file$grade_minimal_response[row],
        file$grade_hallucination[row],
        file$grade_tool[row]
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