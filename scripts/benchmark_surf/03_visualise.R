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
  df$grade_total <- suppressWarnings(as.numeric(as.character(df$grade_total)))
  df$grade_answer <- ifelse(toupper(as.character(df$grade_answer))=="TRUE",1L,
                     ifelse(toupper(as.character(df$grade_answer))=="FALSE",0L,
                     suppressWarnings(as.integer(df$grade_answer))))
  df
}))

averaged <- combined %>%
  group_by(model, backend, id, category) %>%
  summarise(
    grade_answer           = mean(grade_answer,           na.rm = TRUE),
    grade_minimal_response = mean(grade_minimal_response, na.rm = TRUE),
    grade_hallucination    = mean(grade_hallucination,    na.rm = TRUE),
    grade_tool             = mean(grade_tool,             na.rm = TRUE),
    grade_total            = mean(grade_total,            na.rm = TRUE),
    elapsed_sec            = mean(if ("elapsed_sec" %in% names(pick(everything())))
      elapsed_sec else NA_real_, na.rm = TRUE),
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

## ── Canonical category order (all 9) ─────────────────────────
ALL_CATEGORIES <- c(
  "simple", "analytical", "complex",
  "phenotype", "annotation_trap", "unanswerable",
  "rvat", "nonsense", "toolfree"
)
ALL_CATEGORY_LABELS <- c(
  "Simple (S)", "Analytical (A)", "Complex (C)",
  "Phenotype (P)", "Annotation Trap (T)", "Unanswerable (U)",
  "RVAT (R)", "Nonsense (N)", "Toolfree (F)"
)
ALL_CATEGORY_SHORT <- c(
  "Simple", "Analytical", "Complex",
  "Phenotype", "Annot. Trap", "Unanswerable",
  "RVAT", "Nonsense", "Toolfree"
)

## ── Short labels for dual model names ────────────────────────
make_label <- function(model, backend) {
  if (grepl(" -> ", model, fixed = TRUE)) {
    parts <- strsplit(model, " -> ", fixed = TRUE)[[1]]
    paste0(trimws(parts[1]), "\n→ ", trimws(parts[2]))
  } else {
    model
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

missing_backends <- setdiff(backends_in_data, names(backend_colors))
if (length(missing_backends) > 0) {
  extras <- c("#264653","#E9C46A","#A8DADC","#F72585","#4CC9F0")[seq_len(length(missing_backends))]
  backend_colors <- c(backend_colors, setNames(extras, missing_backends))
}

category_colors <- c(
  "simple"          = "#2A9D8F",
  "analytical"      = "#E9C46A",
  "complex"         = "#457B9D",
  "phenotype"       = "#9B5DE5",
  "annotation_trap" = "#F4A261",
  "unanswerable"    = "#E63946",
  "rvat"            = "#06D6A0",
  "nonsense"        = "#FF6B9D",
  "toolfree"        = "#C77DFF"
)

criterion_colors <- c(
  "Answer"           = "#E76F51",
  "Hallucination"    = "#2A9D8F",
  "Minimal_response" = "#457B9D",
  "SQL"              = "#9B5DE5"
)

## ── Shared theme ──────────────────────────────────────────────
theme_als <- function() theme_minimal(base_size = 12) +
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
    title    = "Overall average score per model",
    subtitle = paste0("Averaged across all ", length(unique(averaged$id)), " benchmark questions"),
    x = NULL, y = "Average score (out of 4)",
    caption  = "Criteria: answer correctness · conciseness · hallucination · tool correctness"
  ) +
  theme_als() +
  theme(axis.text.x = element_text(angle = 0))

ggsave(file.path(output_dir, "plot_overall_scores.png"), p1,
       width  = max(10, length(backends_in_data) * 4),
       height = max(4, 2 + n_models * 0.5), dpi = 300)
cat("Plot 1 saved\n")

## ══════════════════════════════════════════════════════════════
## PLOT 2: Backend comparison — grouped by model pairing
## ══════════════════════════════════════════════════════════════
if (multi_backend) {
  
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
    scale_fill_manual(values = backend_colors, name = "Backend") +
    scale_y_continuous(limits = c(0, 4.6), breaks = 0:4,
                       expand = expansion(mult = c(0, 0.08))) +
    labs(
      title    = "Backend comparison — average score per model",
      subtitle = "Each colour represents a different backend architecture",
      x = NULL, y = "Average score (out of 4)",
      caption  = "Higher = better across all 4 grading criteria"
    ) +
    theme_als() +
    theme(axis.text.x = element_text(angle = 30, hjust = 1, size = 8))
  
  ggsave(file.path(output_dir, "plot_backend_comparison.png"), p2,
         width  = max(10, 2 + length(unique(backend_scores$model_short)) * 1.6),
         height = 6, dpi = 300)
  cat("Plot 2 saved\n")
}

## ══════════════════════════════════════════════════════════════
## PLOT 3: Heatmap — faceted by category
## ══════════════════════════════════════════════════════════════

## Build ID order respecting the canonical category order
id_order <- averaged %>%
  distinct(id, category) %>%
  mutate(cat_order = match(category, ALL_CATEGORIES)) %>%
  arrange(cat_order, id) %>%
  pull(id)
averaged$id <- factor(averaged$id, levels = unique(id_order))

## Sort columns: single first, dual last
col_order <- averaged %>%
  distinct(label, backend) %>%
  mutate(is_dual = grepl("→", label)) %>%
  arrange(is_dual, label) %>%
  pull(label)
averaged$label <- factor(averaged$label, levels = unique(col_order))

## Apply category labels — only include categories actually present in data
cats_in_data  <- intersect(ALL_CATEGORIES, unique(averaged$category))
cat_labels_in <- ALL_CATEGORY_LABELS[match(cats_in_data, ALL_CATEGORIES)]

averaged_h <- averaged %>%
  filter(!is.na(category), category %in% cats_in_data) %>%
  mutate(category_label = factor(category,
                                 levels = cats_in_data,
                                 labels = cat_labels_in))

p3 <- ggplot(averaged_h, aes(x = label, y = id, fill = grade_total)) +
  geom_tile(color = "white", linewidth = 0.6) +
  geom_text(aes(label = ifelse(is.na(grade_total), "NA",
                               as.character(round(grade_total, 0)))),
            size = 2.8, fontface = "bold",
            color = ifelse(averaged_h$grade_total < 1.5 | is.na(averaged_h$grade_total),
                           "white", "grey15")) +
  scale_fill_gradient2(
    low      = "#E63946",
    mid      = "#F4A261",
    high     = "#2A9D8F",
    midpoint = 2,
    limits   = c(0, 4),
    na.value = "grey80",
    name     = "Score\n(0–4)"
  ) +
  scale_x_discrete(position = "top") +
  scale_y_discrete(limits = rev) +
  facet_wrap(~category_label,
             ncol   = 2,
             scales = "free_y") +
  labs(
    title    = "Score per question per model — by category",
    subtitle = paste0(length(backends_in_data), " backend(s) · ",
                      n_models, " model(s) · ",
                      length(unique(averaged_h$id)), " questions"),
    x = NULL, y = NULL
  ) +
  theme_als() +
  theme(
    axis.text.x      = element_text(angle = 30, hjust = 0, size = 8),
    axis.text.y      = element_text(size = 8, face = "bold"),
    panel.grid       = element_blank(),
    legend.position  = "right",
    strip.text       = element_text(face = "bold", size = 10,
                                    margin = margin(4, 4, 4, 4)),
    strip.background = element_rect(fill = "#e4f5f2", color = NA),
    panel.spacing    = unit(0.8, "lines")
  )

n_cols    <- length(levels(averaged_h$label))
col_width <- if (any(grepl("→", levels(averaged_h$label)))) 2.0 else 1.5

## Height scales with total question count (more categories = taller)
n_questions_total <- length(unique(averaged_h$id))
plot3_height      <- max(14, ceiling(n_questions_total / 2) * 0.45 + 4)

ggsave(file.path(output_dir, "plot_heatmap.png"), p3,
       width  = max(10, 2 + n_cols * col_width * 2 + 2),
       height = plot3_height, dpi = 300)
cat("Plot 3 saved\n")

## ══════════════════════════════════════════════════════════════
## PLOT 4: Category scores — facet by category, backend on x
## ══════════════════════════════════════════════════════════════
cat_scores <- averaged %>%
  filter(!is.na(category), category %in% cats_in_data) %>%
  group_by(backend, category) %>%
  summarise(mean_total = mean(grade_total, na.rm = TRUE), .groups = "drop") %>%
  mutate(category = factor(category,
                           levels = cats_in_data,
                           labels = ALL_CATEGORY_SHORT[match(cats_in_data, ALL_CATEGORIES)]))

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
    caption  = paste0(
      "Simple = single lookup  ·  Analytical = aggregation  ·  Complex = multi-step  ·  ",
      "Phenotype = multi-table\n",
      "Unanswerable = hallucination trap  ·  RVAT = statistical tests  ·  ",
      "Nonsense = refusal/clarification  ·  Toolfree = pure SQL"
    )
  ) +
  theme_als() +
  theme(axis.text.x = element_text(angle = 30, hjust = 1))

## ncol=3 means up to 3 rows for 9 categories — adjust height accordingly
n_cat_panels <- length(unique(cat_scores$category))
plot4_height <- max(5, ceiling(n_cat_panels / 3) * 3.5)

ggsave(file.path(output_dir, "plot_category_scores.png"), p4,
       width = 12, height = plot4_height, dpi = 300)
cat("Plot 4 saved\n")

## ══════════════════════════════════════════════════════════════
## PLOT 5: Criteria scores — facet by criterion, backend on x
## ══════════════════════════════════════════════════════════════
crit_scores <- averaged %>%
  group_by(backend) %>%
  summarise(
    `Answer correct`     = mean(grade_answer,           na.rm = TRUE),
    `Concise response`   = mean(grade_minimal_response, na.rm = TRUE),
    `Hallucination free` = mean(grade_hallucination,    na.rm = TRUE),
    `Tool correct`       = mean(grade_tool,             na.rm = TRUE),
    .groups = "drop"
  ) %>%
  pivot_longer(cols = c(`Answer correct`, `Concise response`,
                        `Hallucination free`, `Tool correct`),
               names_to = "criterion", values_to = "score")

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
    caption  = "Answer correct · Concise response · Hallucination free · Tool correct"
  ) +
  theme_als() +
  theme(axis.text.x = element_text(angle = 30, hjust = 1))

ggsave(file.path(output_dir, "plot_criteria_scores.png"), p5,
       width = 14, height = 5, dpi = 300)
cat("Plot 5 saved\n")

## ══════════════════════════════════════════════════════════════
## PLOT 6: Response time — average seconds per category per backend
## ══════════════════════════════════════════════════════════════
if ("elapsed_sec" %in% colnames(averaged)) {
  
  time_cat <- averaged %>%
    filter(!is.na(elapsed_sec), !is.na(category), category %in% cats_in_data) %>%
    group_by(backend, category) %>%
    summarise(mean_sec = mean(elapsed_sec, na.rm = TRUE), .groups = "drop") %>%
    mutate(
      category = factor(category,
                        levels = cats_in_data,
                        labels = ALL_CATEGORY_SHORT[match(cats_in_data, ALL_CATEGORIES)]),
      time_label = ifelse(
        mean_sec >= 60,
        sprintf("%d:%02d min", as.integer(mean_sec) %/% 60L,
                as.integer(mean_sec) %% 60L),
        sprintf("%.1f sec", mean_sec)
      )
    )
  
  p6 <- ggplot(time_cat,
               aes(x = category, y = mean_sec, fill = backend)) +
    geom_col(position = position_dodge(width = 0.72),
             width = 0.65, alpha = 0.9) +
    geom_text(aes(label = time_label),
              position = position_dodge(width = 0.72),
              vjust = -0.4, size = 2.8, fontface = "bold", color = "grey20") +
    scale_fill_manual(values = backend_colors, name = "Backend") +
    scale_y_continuous(
      expand = expansion(mult = c(0, 0.15)),
      labels = function(x) ifelse(x >= 60,
                                  sprintf("%d:%02d min",
                                          as.integer(x) %/% 60L,
                                          as.integer(x) %% 60L),
                                  sprintf("%.0f sec", x))
    ) +
    labs(
      title    = "Average response time per question category",
      subtitle = "Time measured from question submission to final response",
      x = NULL, y = "Mean elapsed time",
      caption  = "Includes all agentic loop steps · excludes the 2-sec inter-question sleep"
    ) +
    theme_als() +
    theme(axis.text.x = element_text(angle = 30, hjust = 1))
  
  ggsave(file.path(output_dir, "plot_timing.png"), p6,
         width = max(12, n_cat_panels * 1.4), height = 5, dpi = 300)
  cat("Plot 6 saved\n")
  
} else {
  cat("Plot 6 skipped — no elapsed_sec column in data\n")
}

## ══════════════════════════════════════════════════════════════
## PLOT 7: Questions answered correctly — grade_answer=TRUE count
## ══════════════════════════════════════════════════════════════
correct_counts <- combined %>%
  filter(!is.na(grade_answer)) %>%
  group_by(backend, model) %>%
  summarise(
    n_correct = sum(as.integer(grade_answer) == 1, na.rm = TRUE),
    n_total   = n(),
    pct       = round(100 * n_correct / n_total, 1),
    .groups   = "drop"
  ) %>%
  mutate(bar_label = paste0(n_correct, "/", n_total))

back_cols <- c(
  "agentic_single"   = "#E9C46A",
  "agentic_dual"     = "#2A9D8F",
  "agentic_adaptive" = "#457B9D"
)

p7 <- ggplot(correct_counts,
             aes(x = reorder(backend, n_correct), y = n_correct, fill = backend)) +
  geom_col(width = 0.55, show.legend = FALSE) +
  geom_text(aes(label = bar_label),
            hjust = -0.15, size = 4.5, fontface = "bold") +
  geom_text(aes(label = paste0("(", pct, "%)")),
            hjust = -0.15, vjust = 1.6, size = 3.4, color = "grey45") +
  scale_fill_manual(values = back_cols, na.value = "#cccccc") +
  scale_y_continuous(
    limits = c(0, max(correct_counts$n_total) * 1.18),
    breaks = seq(0, max(correct_counts$n_total), 10)
  ) +
  coord_flip() +
  labs(
    title    = "Questions answered correctly per pipeline",
    subtitle = "Based on grade_answer only — hallucination and tool scores excluded",
    x = NULL, y = "Questions correct",
    caption  = paste0("Out of ", max(correct_counts$n_total), " questions total  ·  ",
                      "A high score here with a low overall score indicates verbose/hallucinating responses")
  ) +
  theme_als() +
  theme(
    panel.grid.major.y = element_blank(),
    panel.grid.major.x = element_line(color = "#e8e8e8")
  )

ggsave(file.path(output_dir, "plot_correct_counts.png"), p7,
       width  = 9,
       height = max(3, nrow(correct_counts) * 0.9 + 1.5), dpi = 300)
cat("Plot 7 saved\n")

## ══════════════════════════════════════════════════════════════
## PLOT 8: Nonsense & Toolfree breakdown — refusal / clarification
## behaviour for new categories side by side
## ══════════════════════════════════════════════════════════════
new_cats <- c("nonsense", "toolfree")
if (any(new_cats %in% unique(averaged$category))) {
  
  new_cat_scores <- averaged %>%
    filter(category %in% new_cats) %>%
    group_by(backend, model, category) %>%
    summarise(
      mean_answer      = mean(grade_answer,           na.rm = TRUE),
      mean_halluc      = mean(grade_hallucination,    na.rm = TRUE),
      mean_total       = mean(grade_total,            na.rm = TRUE),
      .groups = "drop"
    ) %>%
    pivot_longer(cols = c(mean_answer, mean_halluc, mean_total),
                 names_to = "metric", values_to = "score") %>%
    mutate(
      metric   = recode(metric,
                        "mean_answer" = "Answer correct",
                        "mean_halluc" = "Hallucination free",
                        "mean_total"  = "Total score"),
      category = factor(category,
                        levels = new_cats,
                        labels = c("Nonsense (N)", "Toolfree (F)"))
    )
  
  p8 <- ggplot(new_cat_scores,
               aes(x = backend, y = score, fill = metric)) +
    geom_col(position = position_dodge(width = 0.72), width = 0.65, alpha = 0.9) +
    geom_text(aes(label = sprintf("%.2f", score)),
              position = position_dodge(width = 0.72),
              vjust = -0.5, size = 2.8, fontface = "bold", color = "grey20") +
    scale_fill_manual(
      values = c("Answer correct"     = "#E76F51",
                 "Hallucination free" = "#2A9D8F",
                 "Total score"        = "#457B9D"),
      name = "Metric"
    ) +
    scale_y_continuous(limits = c(0, 4.5), breaks = 0:4,
                       expand = expansion(mult = c(0, 0.12))) +
    facet_wrap(~category, ncol = 2) +
    labs(
      title    = "Nonsense & Toolfree category performance",
      subtitle = "Answer correctness, hallucination rate, and total score per backend",
      x = NULL, y = "Score / proportion",
      caption  = paste0(
        "Nonsense: model must refuse impossible questions or ask for clarification\n",
        "Toolfree: complex SQL questions answerable without MCP tools"
      )
    ) +
    theme_als() +
    theme(axis.text.x = element_text(angle = 30, hjust = 1))
  
  ggsave(file.path(output_dir, "plot_new_categories.png"), p8,
         width = 10, height = 5, dpi = 300)
  cat("Plot 8 saved\n")
  
} else {
  cat("Plot 8 skipped — no nonsense or toolfree questions in data\n")
}

cat("\nAll plots saved to:", output_dir, "\n")
