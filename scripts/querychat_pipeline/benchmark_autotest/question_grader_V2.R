
question_grader <- function (answers, outfile_name) {

# read file and add grade column
file <- read.csv(here::here(answers))
file$grade <- NA

# Print row and ask if answer is true or false
for (row in 1:nrow(file)) {
  cat("======================================================================\n")
  print(t(file[row, ]))
  cat("======================================================================\n")
  answer <- ""
  answer <- toupper(readline("Answer correct? (T/F): "))
  file$grade[row] <- answer == "T"
  }

# Create new csv file with grades
write.csv(file, paste0(outfile_name, ".csv"), row.names = F)
}


question_grader("grading_results.csv", "benchmark_graded")

