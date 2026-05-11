question_grader <- function (answers, outfile_name) {
  
  # read file and add grade columns
  file <- read.csv(here::here(answers))
  file$grade_reponse <- NA
  file$grade_minimal_answer <- NA
  file$grade_hallucination <- NA
  file$grade_sql <- NA
  file$grade_total <- NA
  
  # Print row and ask if answer is true or false
  for (row in 1:nrow(file)) {
    cat("======================================================================\n")
    cat("======================================================================\n")
    cat("(", row, "/", nrow(file), ")\n", sep = "")
    cat(paste(names(file)[!grepl("^grade", names(file))], 
              unlist(file[row, !grepl("^grade", names(file))]), 
              sep = "\n", collapse = "\n\n"), "\n")
    cat("======================================================================\n")
    
    file$grade_answer[row] <- toupper(readline("Answer correct? (T/F): ")) == "T"
    file$grade_minimal_response[row] <- toupper(readline("Minimal response? (T/F): ")) == "T"
    file$grade_hallucination[row] <- toupper(readline("Hallucination? (T/F): ")) == "T"
    file$grade_sql[row] <- toupper(readline("SQL correct? (T/F): ")) == "T"
    file$grade_total[row] <- sum(file$grade_answer[row],
                                 file$grade_minimal_answer[row],
                                 file$grade_hallucination[row],
                                 file$grade_sql[row])
  }
  # print end of function
  mean_grade <- round(mean(file$grade_total), digits = 1)
  cat("*******************************************")
  cat("Done\n")
  cat("The average score is: (",mean_grade,"/4)\n", sep = "")
  cat("*******************************************")
  
  # Create new csv file with grades
  write.csv(file, paste0(outfile_name, ".csv"), row.names = F)
}