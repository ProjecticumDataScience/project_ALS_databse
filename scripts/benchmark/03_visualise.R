## ============================================================
## 03_visualise.R
## Produce comparison plots from graded benchmark CSVs.
## ============================================================

library(ggplot2)
library(dplyr)
library(tidyr)
library(scales)

## ── Resolve config ────────────────────────────────────────────
if (!exists("GRADING_DIR")) {
  source(file.path(dirname(sys.frame(1)$ofile), "config.R"))
}

## ── File resolution ───────────────────────────────────────────
if (exists("GRADED_FINAL_CSV") && !is.null(GRADED_FINAL_CSV)) {
  GRADED_FILES <- GRADED_FINAL_CSV
  output_dir   <- dirname(path.expand(GRADED_FINAL_CSV))
  cat("Plotting current run only:\n  ", GRADED_FINAL_CSV, "\n\n")
} else {
  output_dir   <- path.expand(GRADING_DIR)
  GRADED_FILES <- list.files(output_dir, "^finalgraded_.*\\.csv$",
                             recursive = TRUE, full.names = TRUE)
  if (length(GRADED_FILES) == 0) stop("No finalgraded_*.csv found under: ", output_dir)
  cat("Standalone mode —", length(GRADED_FILES), "file(s)\n")
}

## ── Load and combine ──────────────────────────────────────────
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

## ── Detect what's in the data ─────────────────────────────────
backends_in_data <- sort(unique(averaged$backend))
models_in_data   <- sort(unique(averaged$model))
n_models         <- length(models_in_data)
multi_backend    <- length(backends_in_data) > 1

cat("Backends:", paste(backends_in_data, collapse = ", "), "\n")
cat("Models  :", paste(models_in_data,   collapse = ", "), "\n")
cat("Output  :", output_dir, "\n\n")

## ── Short labels for dual model names ────────────────────────
## "llama3.2 -> duckdb-nsql" → "llama3.2\n→ duckdb-nsql"
## Single model names stay as-is
make_label <- function(model, backend) {
  if (grepl(" -> ", model, fixed = TRUE)) {
    parts <- strsplit(model, " -> ", fixed = TRUE)[[1]]
    paste0(trimws(parts[1]), "\n→ ", trimws(parts[2]),
           if (multi_backend) paste0("\n[", backend, "]") else "")
  } else {
    if (multi_backend) paste0(model, "\n(", backend, ")") else model
  }
}

averaged <- averaged %>%
  rowwise() %>%
  mutate(label = make_label(model, backend)) %>%
  ungroup()

## ── Colour palettes ───────────────────────────────────────────
backend_colors <- c(
  "querychat" = "#2A9D8F",
  "mcp"       = "#E76F51",
  "ellmer"    = "#457B9D",
  "dual"      = "#9B5DE5",
  "mcp_dual"  = "#F4A261"
)

## Ensure all backends in data have a colour
missing_backends <- setdiff(backends_in_data, names(backend_colors))
if (length(missing_backends) > 0) {
  extras <- c("#264653","#E9C46A","#A8DADC","#F72585","#4CC9F0")[seq_len(length(missing_backends))]
  backend_colors <- c(backend_colors, setNames(extras, missing_backends))
}

category_colors <- c(
  "analytical"   = "#E9C46A",
  "lookup"       = "#2A9D8F",
  "unanswerable" = "#457B9D"
)

criterion_colors <- c(
  "Answer"           = "#E76F51",
  "Hallucination"    = "#2A9D8F",
  "Minimal_response" = "#457B9D",
  "SQL"              = "#9B5DE5"
)

## ── Shared theme ──────────────────────────────────────────────
theme_als <- theme_minimal(base_size = 12) +
  theme(
    plot.title        = element_text(face = "bold", size = 14,
                                     margin = margin(b = 6)),
    plot.subtitle     = element_text(color = "grey45", size = 10,
                                     margin = margin(b = 10)),
    plot.caption      = element_text(color = "grey55", size = 8,
                                     margin = margin(t = 8)),
    plot.background   = element_rect(fill = "white", color = NA),
    panel.background  = element_rect(fill = "#FAFAFA", color = NA),
    panel.grid.major  = element_line(color = "grey92", linewidth = 0.4),
    panel.grid.minor  = element_blank(),
    axis.title        = element_text(face = "bold", size = 11),
    axis.text         = element_text(color = "grey25", size = 9),
    legend.title      = element_text(face = "bold", size = 10),
    legend.text       = element_text(size = 9),
    legend.background = element_rect(fill = "white", color = NA),
    strip.text        = element_text(face = "bold", size = 11,
                                     margin = margin(b = 6)),
    strip.background  = element_rect(fill = "grey95", color = NA)
  )

## ══════════════════════════════════════════════════════════════
## PLOT 1: Overall score — one bar per backend, facet by backend
## Clean horizontal bars, sorted by score within each facet
## ══════════════════════════════════════════════════════════════
model_scores <- averaged %>%
  group_by(model, backend, label) %>%
  summarise(mean_total = mean(grade_total, na.rm = TRUE), .groups = "drop")

p1 <- ggplot(model_scores,
             aes(x = reorder(label, mean_total),
                 y = mean_total, fill = backend)) +
  geom_col(width = 0.65, alpha = 0.9) +
  geom_text(aes(label = sprintf("%.2f", mean_total)),
            hjust = -0.15, size = 3.2, fontface = "bold", color = "grey20") +
  scale_fill_manual(values = backend_colors, guide = "none") +
  scale_y_continuous(limits = c(0, 4.6), breaks = 0:4,
                     expand = expansion(mult = c(0, 0.05))) +
  coord_flip() +
  facet_wrap(~backend, scales = "free_y", ncol = length(backends_in_data)) +
  labs(
    title   = "Overall average score per model",
    subtitle = "Averaged across all 15 benchmark questions",
    x = NULL, y = "Average score (out of 4)",
    caption = "Criteria: answer correctness · conciseness · hallucination · SQL correctness"
  ) +
  theme_als +
  theme(axis.text.x = element_text(angle = 0))

ggsave(file.path(output_dir, "plot_overall_scores.png"), p1,
       width = max(10, length(backends_in_data) * 4),
       height = max(4, 2 + n_models * 0.5), dpi = 300)
cat("Plot 1 saved\n")

## ══════════════════════════════════════════════════════════════
## PLOT 2: Backend comparison — grouped by model pairing
## Shows each backend as a colour, model on x-axis
## ══════════════════════════════════════════════════════════════
if (multi_backend) {
  
  ## Unique base models (strip orch->sub for grouping)
  backend_scores <- averaged %>%
    group_by(model, backend) %>%
    summarise(mean_total = mean(grade_total, na.rm = TRUE), .groups = "drop") %>%
    mutate(model_short = gsub(" -> ", "\n→ ", model, fixed = TRUE))
  
  p2 <- ggplot(backend_scores,
               aes(x = model_short, y = mean_total, fill = backend)) +
    geom_col(position = position_dodge(width = 0.72),
             width = 0.65, alpha = 0.9) +
    geom_text(aes(label = sprintf("%.2f", mean_total)),
              position = position_dodge(width = 0.72),
              vjust = -0.5, size = 2.8, fontface = "bold", color = "grey20") +
    scale_fill_manual(values = backend_colors,
                      name   = "Backend") +
    scale_y_continuous(limits = c(0, 4.6), breaks = 0:4,
                       expand = expansion(mult = c(0, 0.08))) +
    labs(
      title    = "Backend comparison — average score per model",
      subtitle = "Each colour represents a different backend architecture",
      x = NULL, y = "Average score (out of 4)",
      caption  = "Higher = better across all 4 grading criteria"
    ) +
    theme_als +
    theme(axis.text.x = element_text(angle = 30, hjust = 1, size = 8))
  
  ggsave(file.path(output_dir, "plot_backend_comparison.png"), p2,
         width  = max(10, 2 + length(unique(backend_scores$model_short)) * 1.6),
         height = 6, dpi = 300)
  cat("Plot 2 saved\n")
}

## ══════════════════════════════════════════════════════════════
## PLOT 3: Heatmap — question × model, coloured by score
## Grouped by L/A/U with separator lines
## ══════════════════════════════════════════════════════════════
averaged$id <- factor(averaged$id,
                      levels = c("L1","L2","L3","L4","L5",
                                 "A1","A2","A3","A4","A5",
                                 "U1","U2","U3","U4","U5"))

## Sort columns: single-model backends first, dual last
col_order <- averaged %>%
  distinct(label, backend) %>%
  mutate(is_dual = grepl("→", label)) %>%
  arrange(is_dual, backend, label) %>%
  pull(label)

averaged$label <- factor(averaged$label, levels = unique(col_order))

## Category band colours for y-axis strips
cat_band <- data.frame(
  ymin  = c(0.5, 5.5, 10.5),
  ymax  = c(5.5, 10.5, 15.5),
  fill  = c("#EBF5FB", "#FEF9E7", "#EBF5FB"),
  label = c("Lookup", "Analytical", "Unanswerable")
)

p3 <- ggplot(averaged, aes(x = label, y = id, fill = grade_total)) +
  geom_tile(color = "white", linewidth = 0.7) +
  geom_text(aes(label = ifelse(is.na(grade_total), "NA",
                               as.character(round(grade_total, 1)))),
            size = 3, fontface = "bold",
            color = ifelse(averaged$grade_total < 1.5, "white", "grey15")) +
  scale_fill_gradient2(
    low      = "#E63946",
    mid      = "#F4A261",
    high     = "#2A9D8F",
    midpoint = 2,
    limits   = c(0, 4),
    na.value = "grey80",
    name     = "Score\n(0 – 4)"
  ) +
  scale_x_discrete(position = "top") +
  scale_y_discrete(limits = rev) +
  ## Horizontal separators between L/A/U groups
  geom_hline(yintercept = c(5.5, 10.5),
             color = "white", linewidth = 2) +
  labs(
    title   = "Score per question per model",
    subtitle = paste0(length(backends_in_data), " backend(s) · ",
                      n_models, " model(s) · 15 questions"),
    x = NULL, y = NULL,
    caption = "L = Lookup   A = Analytical   U = Unanswerable"
  ) +
  theme_als +
  theme(
    axis.text.x   = element_text(angle = 30, hjust = 0, size = 8),
    axis.text.y   = element_text(size = 9, face = "bold"),
    panel.grid    = element_blank(),
    legend.position = "right"
  )

n_cols    <- length(levels(averaged$label))
col_width <- if (any(grepl("→", levels(averaged$label)))) 1.9 else 1.4

ggsave(file.path(output_dir, "plot_heatmap.png"), p3,
       width  = max(8, 3 + n_cols * col_width),
       height = 8, dpi = 300)
cat("Plot 3 saved\n")

## ══════════════════════════════════════════════════════════════
## PLOT 4: Category scores — facet by category, backend on x
## Much cleaner than model on x with category colours
## ══════════════════════════════════════════════════════════════
cat_scores <- averaged %>%
  group_by(backend, category) %>%
  summarise(mean_total = mean(grade_total, na.rm = TRUE), .groups = "drop") %>%
  mutate(category = factor(category,
                           levels = c("lookup","analytical","unanswerable"),
                           labels = c("Lookup","Analytical","Unanswerable")))

p4 <- ggplot(cat_scores,
             aes(x = backend, y = mean_total, fill = backend)) +
  geom_col(width = 0.6, alpha = 0.9) +
  geom_text(aes(label = sprintf("%.2f", mean_total)),
            vjust = -0.5, size = 3, fontface = "bold", color = "grey20") +
  scale_fill_manual(values = backend_colors, guide = "none") +
  scale_y_continuous(limits = c(0, 4.5), breaks = 0:4,
                     expand = expansion(mult = c(0, 0.1))) +
  facet_wrap(~category, ncol = 3) +
  labs(
    title    = "Average score per question category",
    subtitle = "Grouped by question type — each backend shown separately",
    x = NULL, y = "Average score (out of 4)",
    caption  = "Lookup = factual gene/variant queries   Analytical = aggregations   Unanswerable = hallucination tests"
  ) +
  theme_als +
  theme(axis.text.x = element_text(angle = 30, hjust = 1))

ggsave(file.path(output_dir, "plot_category_scores.png"), p4,
       width = 12, height = 5, dpi = 300)
cat("Plot 4 saved\n")

## ══════════════════════════════════════════════════════════════
## PLOT 5: Criteria scores — facet by criterion, backend on x
## ══════════════════════════════════════════════════════════════
crit_scores <- averaged %>%
  group_by(backend) %>%
  summarise(
    Answer           = mean(grade_answer,           na.rm = TRUE),
    Minimal_response = mean(grade_minimal_response, na.rm = TRUE),
    Hallucination    = mean(grade_hallucination,    na.rm = TRUE),
    SQL              = mean(grade_sql,              na.rm = TRUE),
    .groups = "drop"
  ) %>%
  pivot_longer(cols = c(Answer, Minimal_response, Hallucination, SQL),
               names_to = "criterion", values_to = "score") %>%
  mutate(criterion = recode(criterion,
                            "Answer"           = "Answer correct",
                            "Minimal_response" = "Concise response",
                            "Hallucination"    = "Hallucination free",
                            "SQL"              = "SQL correct"
  ))

p5 <- ggplot(crit_scores,
             aes(x = backend, y = score, fill = backend)) +
  geom_col(width = 0.6, alpha = 0.9) +
  geom_text(aes(label = percent(score, accuracy = 1)),
            vjust = -0.5, size = 3, fontface = "bold", color = "grey20") +
  scale_fill_manual(values = backend_colors, guide = "none") +
  scale_y_continuous(limits = c(0, 1.15), breaks = seq(0, 1, 0.25),
                     labels = percent,
                     expand = expansion(mult = c(0, 0.1))) +
  facet_wrap(~criterion, ncol = 4) +
  labs(
    title    = "Pass rate per grading criterion",
    subtitle = "Each criterion scored as pass / fail per question",
    x = NULL, y = "Proportion correct",
    caption  = "Averaged across all models and questions within each backend"
  ) +
  theme_als +
  theme(axis.text.x = element_text(angle = 30, hjust = 1))

ggsave(file.path(output_dir, "plot_criteria_scores.png"), p5,
       width = 14, height = 5, dpi = 300)
cat("Plot 5 saved\n")

cat("\nAll plots saved to:", output_dir, "\n")
