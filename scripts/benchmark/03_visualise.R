## ============================================================
## 03_visualise.R
## Produce comparison plots from graded benchmark CSVs.
##
## Pipeline mode (sourced from run_pipeline.R):
##   Uses only GRADED_FINAL_CSV from the current run.
##   Plots saved into the same grading_<datetime>/ folder.
##
## Standalone mode (--visualise-only):
##   Discovers all finalgraded_*.csv under GRADING_DIR and
##   averages across them. Plots saved into GRADING_DIR root.
## ============================================================

library(ggplot2)
library(dplyr)
library(tidyr)
library(scales)

## ── Resolve config if needed ──────────────────────────────────
if (!exists("GRADING_DIR")) {
  source(file.path(dirname(sys.frame(1)$ofile), "config.R"))
}

## ── Decide which files to use and where to save plots ────────
if (exists("GRADED_FINAL_CSV") && !is.null(GRADED_FINAL_CSV)) {
  ## Pipeline mode — current run only, plots go next to the CSV
  GRADED_FILES <- GRADED_FINAL_CSV
  output_dir   <- dirname(path.expand(GRADED_FINAL_CSV))
  cat("Plotting current run only:\n  ", GRADED_FINAL_CSV, "\n\n")
} else {
  ## Standalone mode — combine all discovered files
  output_dir   <- path.expand(GRADING_DIR)
  GRADED_FILES <- list.files(
    path       = output_dir,
    pattern    = "^finalgraded_.*\\.csv$",
    recursive  = TRUE,
    full.names = TRUE
  )
  if (length(GRADED_FILES) == 0) {
    stop("No finalgraded_*.csv files found under: ", output_dir)
  }
  cat("Standalone mode — combining", length(GRADED_FILES), "graded file(s):\n")
  cat(paste0("  ", GRADED_FILES, collapse = "\n"), "\n\n")
}

## ── Combine ───────────────────────────────────────────────────
combined <- do.call(rbind, lapply(GRADED_FILES, function(f) {
  df <- read.csv(f)
  if (!"backend" %in% colnames(df)) df$backend <- "querychat"
  df
}))

averaged <- combined %>%
  group_by(model, backend, id, category) %>%
  summarise(
    grade_answer           = mean(grade_answer,           na.rm = TRUE),
    grade_minimal_response = mean(grade_minimal_response, na.rm = TRUE),
    grade_hallucination    = mean(grade_hallucination,    na.rm = TRUE),
    grade_sql              = mean(grade_sql,              na.rm = TRUE),
    grade_total            = mean(grade_total,            na.rm = TRUE),
    .groups = "drop"
  )

write.csv(averaged, file.path(output_dir, "combined_averaged.csv"), row.names = FALSE)
cat("Output directory:", output_dir, "\n")
cat("Combined averaged file saved!\n")

## ── Detect backends and models ───────────────────────────────
backends_in_data <- sort(unique(averaged$backend))
models_in_data   <- sort(unique(averaged$model))
n_models         <- length(models_in_data)
multi_backend    <- length(backends_in_data) > 1

cat("Backends detected:", paste(backends_in_data, collapse = ", "), "\n")
cat("Models detected  :", paste(models_in_data,   collapse = ", "), "\n")

## ── Colour palettes ───────────────────────────────────────────
palette_pool <- c(
  "#E63946", "#F4A261", "#2A9D8F", "#457B9D", "#9B5DE5",
  "#E9C46A", "#264653", "#A8DADC", "#F72585", "#4CC9F0",
  "#06D6A0", "#FFB703", "#FB8500", "#8338EC", "#3A86FF"
)
model_colors <- setNames(palette_pool[seq_len(n_models)], models_in_data)

backend_colors <- c(
  "querychat" = "#2A9D8F",
  "mcp"       = "#E63946",
  "ellmer"    = "#F4A261",
  "dual"      = "#9B5DE5"
)

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
    strip.text       = element_text(face = "bold", size = 12),
    plot.caption     = element_text(color = "grey50", size = 9, margin = margin(t = 10))
  )

## ── Plot 1: Overall score per model ───────────────────────────
model_scores <- averaged %>%
  group_by(model, backend) %>%
  summarise(mean_total = mean(grade_total, na.rm = TRUE), .groups = "drop")

p1 <- ggplot(model_scores, aes(x = reorder(model, mean_total),
                               y = mean_total, fill = model)) +
  geom_bar(stat = "identity", width = 0.7) +
  geom_text(aes(label = round(mean_total, 2)),
            hjust = -0.2, size = 4, fontface = "bold") +
  scale_fill_manual(values = model_colors) +
  scale_y_continuous(limits = c(0, 4.5), breaks = 0:4) +
  coord_flip() +
  labs(
    title    = "Overall average score per model",
    subtitle = paste0("Backends: ", paste(backends_in_data, collapse = " vs ")),
    x = NULL, y = "Average score (out of 4)",
    caption = "Scoring: answer correctness, conciseness, hallucination, SQL correctness"
  ) +
  theme_als +
  theme(legend.position = "none", axis.text.x = element_text(angle = 0))

if (multi_backend) p1 <- p1 + facet_wrap(~backend, ncol = length(backends_in_data))

ggsave(file.path(output_dir, "plot_overall_scores.png"), p1,
       width = if (multi_backend) 14 else 9,
       height = max(4, 1 + n_models * 0.7), dpi = 300)
cat("Plot 1 saved!\n")

## ── Plot 2b: Backend comparison (multi-backend only) ─────────
if (multi_backend) {
  backend_scores <- averaged %>%
    group_by(model, backend) %>%
    summarise(mean_total = mean(grade_total, na.rm = TRUE), .groups = "drop")
  
  p2b <- ggplot(backend_scores, aes(x = model, y = mean_total, fill = backend)) +
    geom_bar(stat = "identity", position = "dodge", width = 0.7) +
    geom_text(aes(label = round(mean_total, 2)),
              position = position_dodge(width = 0.7),
              vjust = -0.4, size = 3.5, fontface = "bold") +
    scale_fill_manual(values = backend_colors) +
    scale_y_continuous(limits = c(0, 4.5), breaks = 0:4) +
    labs(
      title    = "Backend comparison — score per model",
      subtitle = "Direct backend comparison, averaged across all questions",
      x = "Model", y = "Average score (out of 4)", fill = "Backend",
      caption = "Higher = better across all 4 grading criteria"
    ) +
    theme_als
  
  ggsave(file.path(output_dir, "plot_backend_comparison.png"), p2b,
         width = max(8, 3 + n_models * 1.5), height = 6, dpi = 300)
  cat("Plot 2b (backend comparison) saved!\n")
}

## ── Plot 2: Score per category per model ─────────────────────
category_scores <- averaged %>%
  group_by(model, backend, category) %>%
  summarise(mean_total = mean(grade_total, na.rm = TRUE), .groups = "drop")

p2 <- ggplot(category_scores, aes(x = model, y = mean_total, fill = category)) +
  geom_bar(stat = "identity", position = "dodge", width = 0.7) +
  geom_text(aes(label = round(mean_total, 1)),
            position = position_dodge(width = 0.7),
            vjust = -0.4, size = 3.2, fontface = "bold") +
  scale_fill_manual(values = category_colors,
                    labels = c("Analytical", "Lookup", "Unanswerable")) +
  scale_y_continuous(limits = c(0, 4.8), breaks = 0:4) +
  labs(
    title    = "Average score per question category per model",
    subtitle = paste0("Backends: ", paste(backends_in_data, collapse = " vs ")),
    x = "Model", y = "Average score (out of 4)", fill = "Category",
    caption = "Lookup = factual | Analytical = aggregations | Unanswerable = hallucination tests"
  ) +
  theme_als

if (multi_backend) p2 <- p2 + facet_wrap(~backend, ncol = length(backends_in_data))

ggsave(file.path(output_dir, "plot_category_scores.png"), p2,
       width = if (multi_backend) 16 else max(8, 3 + n_models * 1.5),
       height = 6, dpi = 300)
cat("Plot 2 saved!\n")

## ── Plot 3: Heatmap ───────────────────────────────────────────
averaged$id <- factor(averaged$id,
                      levels = c("L1","L2","L3","L4","L5",
                                 "A1","A2","A3","A4","A5",
                                 "U1","U2","U3","U4","U5"))

## For dual backend, model already contains "orch -> sub" so just use it.
## For other backends, append (backend) only when multiple backends are present.
averaged <- averaged %>%
  mutate(model_backend = case_when(
    backend == "dual"  ~ paste0(model, "\n[dual]"),
    multi_backend      ~ paste0(model, "\n(", backend, ")"),
    TRUE               ~ model
  ))

p3 <- ggplot(averaged, aes(x = model_backend, y = id, fill = grade_total)) +
  geom_tile(color = "white", linewidth = 0.8) +
  geom_text(aes(label = round(grade_total, 1)),
            size = 3.5, fontface = "bold", color = "grey20") +
  scale_fill_gradient2(low = "#E63946", mid = "#F4A261", high = "#2A9D8F",
                       midpoint = 2, limits = c(0, 4), name = "Score\n(0-4)") +
  scale_x_discrete(position = "top") +
  labs(
    title    = "Score per question per model",
    subtitle = paste0("Backends: ", paste(backends_in_data, collapse = " vs ")),
    x = NULL, y = "Question ID",
    caption = "L = Lookup | A = Analytical | U = Unanswerable"
  ) +
  theme_als +
  theme(axis.text.x = element_text(angle = 0, hjust = 0.5), panel.grid = element_blank())

n_cols <- length(unique(averaged$model_backend))
## Dual labels are wider — give them more space per column
col_width <- if ("dual" %in% backends_in_data) 2.0 else 1.4
ggsave(file.path(output_dir, "plot_heatmap.png"), p3,
       width = max(7, 2 + n_cols * col_width), height = 9, dpi = 300)
cat("Plot 3 saved!\n")

## ── Plot 4: Score per criterion per model ─────────────────────
criterion_scores <- averaged %>%
  group_by(model, backend) %>%
  summarise(
    Answer           = mean(grade_answer,           na.rm = TRUE),
    Minimal_response = mean(grade_minimal_response, na.rm = TRUE),
    Hallucination    = mean(grade_hallucination,    na.rm = TRUE),
    SQL              = mean(grade_sql,              na.rm = TRUE),
    .groups = "drop"
  ) %>%
  pivot_longer(cols = c(Answer, Minimal_response, Hallucination, SQL),
               names_to = "criterion", values_to = "score")

p4 <- ggplot(criterion_scores, aes(x = model, y = score, fill = criterion)) +
  geom_bar(stat = "identity", position = "dodge", width = 0.7) +
  geom_text(aes(label = round(score, 2)),
            position = position_dodge(width = 0.7),
            vjust = -0.4, size = 3, fontface = "bold") +
  scale_fill_manual(values = criterion_colors,
                    labels = c("Answer", "Hallucination free", "Minimal response", "SQL correct")) +
  scale_y_continuous(limits = c(0, 1.15), breaks = seq(0, 1, 0.25), labels = percent) +
  labs(
    title    = "Score per grading criterion per model",
    subtitle = paste0("Backends: ", paste(backends_in_data, collapse = " vs ")),
    x = "Model", y = "Proportion correct", fill = "Criterion",
    caption = "Each criterion scored as pass/fail per question"
  ) +
  theme_als

if (multi_backend) p4 <- p4 + facet_wrap(~backend, ncol = length(backends_in_data))

ggsave(file.path(output_dir, "plot_criteria_scores.png"), p4,
       width = if (multi_backend) 16 else max(8, 3 + n_models * 1.5),
       height = 6, dpi = 300)
cat("Plot 4 saved!\n")

cat("\nAll plots saved to:", output_dir, "\n")
