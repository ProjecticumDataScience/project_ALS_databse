## ============================================================
## 03_visualise.R
## Combine graded CSVs and produce plots.
## Models and their colours are derived automatically from the
## data – no hard-coded model names anywhere.
## ============================================================

library(ggplot2)
library(dplyr)
library(tidyr)
library(scales)

## ── Resolve grading directory ─────────────────────────────────
if (!exists("GRADING_DIR")) {
  source(file.path(dirname(sys.frame(1)$ofile), "config.R"))
}
output_dir <- path.expand(GRADING_DIR)

## ── Auto-discover all finalgraded CSVs under GRADING_DIR ──────
## Walks all grading_* subdirectories and picks up every
## finalgraded_*.csv it finds. No manual list needed.
GRADED_FILES <- list.files(
  path       = output_dir,
  pattern    = "^finalgraded_.*\\.csv$",
  recursive  = TRUE,
  full.names = TRUE
)

if (length(GRADED_FILES) == 0) {
  stop("No finalgraded_*.csv files found under: ", output_dir,
       "\nRun 02_grade.R first, or check your GRADING_DIR in config.R.")
}
cat("Found", length(GRADED_FILES), "graded file(s):\n")
cat(paste0("  ", GRADED_FILES, collapse = "\n"), "\n\n")

## ── Combine and average all runs ─────────────────────────────
combined <- do.call(rbind, lapply(GRADED_FILES, read.csv))

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

write.csv(averaged, file.path(output_dir, "combined_averaged.csv"), row.names = FALSE)
cat("Combined averaged file saved!\n")

## ── Derive model list and assign colours dynamically ─────────
## Colours cycle through a palette; adding more models just works.
models_in_data <- sort(unique(averaged$model))
n_models       <- length(models_in_data)

palette_pool <- c(
  "#E63946", "#F4A261", "#2A9D8F", "#457B9D", "#9B5DE5",
  "#E9C46A", "#264653", "#A8DADC", "#F72585", "#4CC9F0",
  "#06D6A0", "#FFB703", "#FB8500", "#8338EC", "#3A86FF"
)
model_colors <- setNames(
  palette_pool[seq_len(n_models)],
  models_in_data
)
cat("Models detected:", paste(models_in_data, collapse = ", "), "\n")

## ── Shared theme ──────────────────────────────────────────────
category_colors <- c(
  "analytical"   = "#E9C46A",
  "lookup"       = "#2A9D8F",
  "unanswerable" = "#457B9D"
)

criterion_colors <- c(
  "Answer"           = "#E63946",
  "Hallucination"    = "#2A9D8F",
  "Minimal_response" = "#457B9D",
  "SQL"              = "#9B5DE5"
)

theme_als <- theme_minimal(base_size = 13) +
  theme(
    plot.title       = element_text(face = "bold", size = 15, margin = margin(b = 10)),
    plot.subtitle    = element_text(color = "grey40", size = 11, margin = margin(b = 10)),
    axis.title       = element_text(face = "bold"),
    axis.text        = element_text(color = "grey20"),
    axis.text.x      = element_text(angle = 45, hjust = 1),
    legend.title     = element_text(face = "bold"),
    panel.grid.minor = element_blank(),
    panel.grid.major = element_line(color = "grey90"),
    plot.caption     = element_text(color = "grey50", size = 9, margin = margin(t = 10))
  )

## ── Plot 1: Overall score per model ───────────────────────────
model_scores <- averaged %>%
  group_by(model) %>%
  summarise(mean_total = mean(grade_total, na.rm = TRUE), .groups = "drop")

p1 <- ggplot(model_scores, aes(x = reorder(model, mean_total),
                               y = mean_total,
                               fill = model)) +
  geom_bar(stat = "identity", width = 0.7) +
  geom_text(aes(label = round(mean_total, 2)),
            hjust = -0.2, size = 4, fontface = "bold") +
  scale_fill_manual(values = model_colors) +
  scale_y_continuous(limits = c(0, 4.5), breaks = 0:4) +
  coord_flip() +
  labs(
    title    = "Overall average score per model",
    subtitle = paste0(
      "Averaged across ", length(GRADED_FILES), " benchmark run(s), 15 questions each"
    ),
    x        = NULL,
    y        = "Average score (out of 4)",
    caption  = "Scoring criteria: answer correctness, response conciseness, hallucination, SQL correctness"
  ) +
  theme_als +
  theme(
    legend.position = "none",
    axis.text.x     = element_text(angle = 0)
  )

ggsave(file.path(output_dir, "plot_overall_scores.png"), p1,
       width = 9, height = max(4, 1 + n_models * 0.7), dpi = 300)
cat("Plot 1 saved!\n")

## ── Plot 2: Score per category per model ──────────────────────
category_scores <- averaged %>%
  group_by(model, category) %>%
  summarise(mean_total = mean(grade_total, na.rm = TRUE), .groups = "drop")

p2 <- ggplot(category_scores, aes(x = model, y = mean_total, fill = category)) +
  geom_bar(stat = "identity", position = "dodge", width = 0.7) +
  geom_text(aes(label = round(mean_total, 1)),
            position = position_dodge(width = 0.7),
            vjust = -0.4, size = 3.2, fontface = "bold") +
  scale_fill_manual(
    values = category_colors,
    labels = c("Analytical", "Lookup", "Unanswerable")
  ) +
  scale_y_continuous(limits = c(0, 4.8), breaks = 0:4) +
  labs(
    title    = "Average score per question category per model",
    subtitle = paste0("Averaged across ", length(GRADED_FILES), " benchmark run(s)"),
    x        = "Model",
    y        = "Average score (out of 4)",
    fill     = "Category",
    caption  = "Lookup = factual queries | Analytical = aggregations | Unanswerable = hallucination tests"
  ) +
  theme_als

ggsave(file.path(output_dir, "plot_category_scores.png"), p2,
       width = max(8, 3 + n_models * 1.5), height = 6, dpi = 300)
cat("Plot 2 saved!\n")

## ── Plot 3: Heatmap ───────────────────────────────────────────
averaged$id <- factor(averaged$id,
                      levels = c("L1","L2","L3","L4","L5",
                                 "A1","A2","A3","A4","A5",
                                 "U1","U2","U3","U4","U5"))

p3 <- ggplot(averaged, aes(x = model, y = id, fill = grade_total)) +
  geom_tile(color = "white", linewidth = 0.8) +
  geom_text(aes(label = round(grade_total, 1)),
            size = 3.5, fontface = "bold", color = "grey20") +
  scale_fill_gradient2(
    low      = "#E63946",
    mid      = "#F4A261",
    high     = "#2A9D8F",
    midpoint = 2,
    limits   = c(0, 4),
    name     = "Score\n(0-4)"
  ) +
  scale_x_discrete(position = "top") +
  labs(
    title    = "Score per question per model",
    subtitle = paste0("Averaged across ", length(GRADED_FILES), " benchmark run(s)"),
    x        = NULL,
    y        = "Question ID",
    caption  = "L = Lookup | A = Analytical | U = Unanswerable"
  ) +
  theme_als +
  theme(
    axis.text.x  = element_text(angle = 45, hjust = 0, vjust = 0),
    panel.grid   = element_blank()
  )

ggsave(file.path(output_dir, "plot_heatmap.png"), p3,
       width = max(7, 2 + n_models * 1.4), height = 9, dpi = 300)
cat("Plot 3 saved!\n")

## ── Plot 4: Score per criterion per model ─────────────────────
criterion_scores <- averaged %>%
  group_by(model) %>%
  summarise(
    Answer           = mean(grade_answer,           na.rm = TRUE),
    Minimal_response = mean(grade_minimal_response, na.rm = TRUE),
    Hallucination    = mean(grade_hallucination,    na.rm = TRUE),
    SQL              = mean(grade_sql,              na.rm = TRUE),
    .groups = "drop"
  ) %>%
  pivot_longer(
    cols      = c(Answer, Minimal_response, Hallucination, SQL),
    names_to  = "criterion",
    values_to = "score"
  )

p4 <- ggplot(criterion_scores, aes(x = model, y = score, fill = criterion)) +
  geom_bar(stat = "identity", position = "dodge", width = 0.7) +
  geom_text(aes(label = round(score, 2)),
            position = position_dodge(width = 0.7),
            vjust = -0.4, size = 3, fontface = "bold") +
  scale_fill_manual(
    values = criterion_colors,
    labels = c("Answer", "Hallucination free", "Minimal response", "SQL correct")
  ) +
  scale_y_continuous(
    limits = c(0, 1.15),
    breaks = seq(0, 1, 0.25),
    labels = percent
  ) +
  labs(
    title    = "Score per grading criterion per model",
    subtitle = paste0("Averaged across ", length(GRADED_FILES), " benchmark run(s)"),
    x        = "Model",
    y        = "Proportion correct",
    fill     = "Criterion",
    caption  = "Each criterion scored as pass/fail per question"
  ) +
  theme_als

ggsave(file.path(output_dir, "plot_criteria_scores.png"), p4,
       width = max(8, 3 + n_models * 1.5), height = 6, dpi = 300)
cat("Plot 4 saved!\n")

cat("\nAll plots saved to:", output_dir, "\n")
