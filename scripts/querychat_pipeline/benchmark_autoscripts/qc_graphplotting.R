library(ggplot2)
library(dplyr)
library(tidyr)

## ============================================================
## Set your finalgraded CSV paths here
## ============================================================
graded_files <- c(
  "~/project_ALS_databse/analysis/benchmark_grading/finalgraded_20260510_141103.csv",
  "~/project_ALS_databse/analysis/benchmark_grading/finalgraded_20260511_010604.csv",
  "~/project_ALS_databse/analysis/benchmark_grading/finalgraded_20260511_093437.csv"
)

## ============================================================
## Combine all runs
## ============================================================
combined <- do.call(rbind, lapply(graded_files, read.csv))

# average grades across runs per model + question
averaged <- combined %>%
  group_by(model, id, category) %>%
  summarise(
    grade_answer           = mean(grade_answer,           na.rm = TRUE),
    grade_minimal_response = mean(grade_minimal_response, na.rm = TRUE),
    grade_hallucination    = mean(grade_hallucination,    na.rm = TRUE),
    grade_sql              = mean(grade_sql,              na.rm = TRUE),
    grade_total            = mean(grade_total,            na.rm = TRUE),
    .groups = "drop"
  )

# save combined averaged file
output_dir <- path.expand("~/project_ALS_databse/analysis/benchmark_grading")
write.csv(averaged, file.path(output_dir, "combined_averaged.csv"), row.names = FALSE)
cat("Combined averaged file saved!\n")

## ============================================================
## Plot 1: Overall score per model (bar chart)
## ============================================================
model_scores <- averaged %>%
  group_by(model) %>%
  summarise(mean_total = mean(grade_total, na.rm = TRUE), .groups = "drop")

p1 <- ggplot(model_scores, aes(x = reorder(model, mean_total), y = mean_total, fill = model)) +
  geom_bar(stat = "identity") +
  geom_text(aes(label = round(mean_total, 2)), hjust = -0.2, size = 3.5) +
  coord_flip() +
  ylim(0, 4) +
  labs(
    title = "Overall average score per model",
    x     = "Model",
    y     = "Average score (out of 4)"
  ) +
  theme_minimal() +
  theme(legend.position = "none")

ggsave(file.path(output_dir, "plot_overall_scores.png"), p1, width = 8, height = 5)

## ============================================================
## Plot 2: Score per category per model
## ============================================================
category_scores <- averaged %>%
  group_by(model, category) %>%
  summarise(mean_total = mean(grade_total, na.rm = TRUE), .groups = "drop")

p2 <- ggplot(category_scores, aes(x = model, y = mean_total, fill = category)) +
  geom_bar(stat = "identity", position = "dodge") +
  ylim(0, 4) +
  labs(
    title = "Average score per category per model",
    x     = "Model",
    y     = "Average score (out of 4)",
    fill  = "Category"
  ) +
  theme_minimal() +
  theme(axis.text.x = element_text(angle = 45, hjust = 1))

ggsave(file.path(output_dir, "plot_category_scores.png"), p2, width = 10, height = 6)

## ============================================================
## Plot 3: Heatmap of score per question per model
## ============================================================
p3 <- ggplot(averaged, aes(x = model, y = id, fill = grade_total)) +
  geom_tile(color = "white") +
  scale_fill_gradient(low = "red", high = "green", limits = c(0, 4)) +
  labs(
    title = "Score per question per model",
    x     = "Model",
    y     = "Question ID",
    fill  = "Score (0-4)"
  ) +
  theme_minimal() +
  theme(axis.text.x = element_text(angle = 45, hjust = 1))

ggsave(file.path(output_dir, "plot_heatmap.png"), p3, width = 10, height = 8)

## ============================================================
## Plot 4: Score per grading criterion per model
## ============================================================
criterion_scores <- averaged %>%
  group_by(model) %>%
  summarise(
    Answer           = mean(grade_answer,           na.rm = TRUE),
    Minimal_response = mean(grade_minimal_response, na.rm = TRUE),
    Hallucination    = mean(grade_hallucination,    na.rm = TRUE),
    SQL              = mean(grade_sql,              na.rm = TRUE),
    .groups = "drop"
  ) %>%
  tidyr::pivot_longer(
    cols      = c(Answer, Minimal_response, Hallucination, SQL),
    names_to  = "criterion",
    values_to = "score"
  )

p4 <- ggplot(criterion_scores, aes(x = model, y = score, fill = criterion)) +
  geom_bar(stat = "identity", position = "dodge") +
  ylim(0, 1) +
  labs(
    title = "Score per grading criterion per model",
    x     = "Model",
    y     = "Proportion correct (0-1)",
    fill  = "Criterion"
  ) +
  theme_minimal() +
  theme(axis.text.x = element_text(angle = 45, hjust = 1))

ggsave(file.path(output_dir, "plot_criteria_scores.png"), p4, width = 10, height = 6)

cat("All plots saved to:", output_dir, "\n")