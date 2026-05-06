# Benchmarking questions for the Chatbot
You can use these benchmarking questions to benchmark the accuracy of the chatbot. The questions are designed to test the chatbot's ability to answer both simple lookup queries and more complex analytical queries. The questions are also designed to test the chatbot's ability to avoid hallucination by asking unanswerable questions. At last, feel free to come up with additional benchmarking questions!

## Load Packages

```r
library(rvat)
library(rvatData)
library(DBI)
```

## Connect to Database

```r
outdir <- tempdir()
gdb <- gdb(rvat_example("rvatData.gdb"))
```

## Inspect the `varInfo_synthetic` Table

```r
dbGetQuery(gdb, "SELECT * FROM varInfo_synthetic LIMIT 5")
```

---

# Lookup Queries

## Select number of variants in NEK1

```r
query <- "
SELECT COUNT(VAR_id) AS number_of_variants
FROM varInfo_synthetic
WHERE gene_name = 'NEK1'
"
sv_NEK1 <- dbGetQuery(gdb, query)
```

**Result:** There are 190 variants.

---

## Select variants in NEK1 that with HighImpact and a CADDphered > 20

```r
query <- "
SELECT VAR_id, gene_name, HighImpact, CADDphred
FROM varInfo_synthetic
WHERE HighImpact = 1 AND CADDphred > 20 AND gene_name = 'NEK1'
"
sv_NEK1_filtered <- dbGetQuery(gdb, query)
```

**Result:** There are 13 variants in NEK1 with a high impact and CADD score above 20.

---

## How many variants in TARDBP are predicted deletorious by SIFT? 

```r
query <- "
SELECT COUNT(*) AS number_of_variants_with_SIFT_D
FROM varInfo_synthetic
WHERE gene_name = 'TARDBP' AND SIFT = 'D'
"
TARDBP_SIFT_D <- dbGetQuery(gdb, query)
```

**Result:** 4 variants are predicted to be deleterious.
Note: the chatbot should interpret that the letter D means "deleterious" in the SIFT column. (It could be good to specify in the instructions for the chatbot what the abbreviations in the table mean).

---

## Which high-impact variants have at least one ALS patient that is homozygous for this variant?

```r
query <- "
SELECT VAR_id, gene_name, HighImpact, ALS_1, ALS_2, ALS_3, ALS_4, ALS_5
FROM varInfo_synthetic
WHERE HighImpact = 1 AND (ALS_1 = 2 OR ALS_2 = 2 OR ALS_3 = 2 OR ALS_4 = 2 OR ALS_5 = 2)
"
homozygous_samples <- dbGetQuery(gdb, query)
```

**Result:** 102 variants have at least one homozygous carrier.

---

## What are the ten most deleterious variants in ABCA4

```r
query <- "
SELECT
  VAR_id,
  gene_name,
  CADDphred,
  SIFT,
  PolyPhen
FROM varInfo_synthetic
WHERE CADDphred > 20 AND SIFT = 'D' AND PolyPhen = 'D' AND gene_name = 'ABCA4'
ORDER BY CADDphred DESC
LIMIT 10;
"
deleterious_variants <- dbGetQuery(gdb, query)
```

> Note: "Most deleterious" is ambiguous and depends on the definition. Here, we use a combination of CADDphred > 20 and both SIFT and PolyPhen predicting deleteriousness. However, other definitions could be used. The important point is that the chatbot should explain its definition of deletoriousness or ask for clarification from the user.

---

# Analytical Queries

## What is the variant with the highest allele frequency?

```r
query <- "
SELECT VAR_id, MAX(AF) AS highest_allele_frequency
FROM varInfo_synthetic
"
highest_AF <- dbGetQuery(gdb, query)
```

**Result:** VAR_id 901 has the highest AF (9.68148e-05).

---

## What is te average allele frequency for synonymous, moderate, and high-impact variants?

```r
query <- "
SELECT
  AVG(CASE WHEN Synonymous = 1 THEN AF END) AS average_AF_synonymous,
  AVG(CASE WHEN ModerateImpact = 1 THEN AF END) AS average_AF_moderate,
  AVG(CASE WHEN HighImpact = 1 THEN AF END) AS average_AF_high
FROM varInfo_synthetic
"
allele_frequencies <- dbGetQuery(gdb, query)
```

---

## How many high-impact variants does the ALS_1 patient carry?

```r
query <- "
SELECT
  SUM(CASE WHEN ALS_1 = 1 THEN 1 ELSE 0 END) AS heterozygous,
  SUM(CASE WHEN ALS_1 = 2 THEN 1 ELSE 0 END) AS homozygous
FROM varInfo_synthetic
WHERE HighImpact = 1;
"
high_impact_variants_per_person <- dbGetQuery(gdb, query)
```

**Result:** 42 heterozygous and 33 homozygous variants.

---

## What is the total burden of cases versus controls (so how many effect alleles do the ALS cases carry vs controls)

```r
query <- "
SELECT
  SUM(ALS_1 + ALS_2 + ALS_3 + ALS_4 + ALS_5) AS total_cases_burden,
  SUM(Control_1 + Control_2 + Control_3 + Control_4 + Control_5) AS total_controls_burden
FROM varInfo_synthetic;
"
total_burden <- dbGetQuery(gdb, query)
```

**Result:** Cases = 9083, Controls = 8974.

---

## Are there more variants in cases than controls?

```r
query <- "
SELECT
  VAR_id,
  gene_name,
  (ALS_1 + ALS_2 + ALS_3 + ALS_4 + ALS_5) AS case_count,
  (Control_1 + Control_2 + Control_3 + Control_4 + Control_5) AS control_count,
  ((ALS_1 + ALS_2 + ALS_3 + ALS_4 + ALS_5) * 1.0) /
  NULLIF((Control_1 + Control_2 + Control_3 + Control_4 + Control_5), 0) AS case_control_ratio
FROM varInfo_synthetic
ORDER BY case_control_ratio DESC
LIMIT 10;
"
case_control_comparison <- dbGetQuery(gdb, query)
```
In this query we select the top 10 variants that have the highest ratio of case count to control count. Note that this can be interpreted differently.
The chatbot should come up with an answer that is true and makes sense based on the data in the table.

---

## Summarize variant info for each gene. Only select genes that have more than 10 variants. Order the results by the number of variants.

```r
query <- "
SELECT
  gene_name,
  CHROM,
  COUNT(*) AS total_variants,
  SUM(CASE WHEN HighImpact = 1 THEN 1 ELSE 0 END) AS high_impact_count,
  SUM(CASE WHEN ModerateImpact = 1 THEN 1 ELSE 0 END) AS moderate_impact_count,
  SUM(CASE WHEN Synonymous = 1 THEN 1 ELSE 0 END) AS synonymous_count,
  AVG(AF) AS mean_AF,
  MIN(POS) AS start_pos,
  MAX(POS) AS end_pos,
  (MAX(POS) - MIN(POS)) AS length
FROM varInfo_synthetic
GROUP BY gene_name, CHROM
HAVING total_variants > 10
ORDER BY total_variants DESC
"
average_age_cases <- dbGetQuery(gdb, query)
```


The chatbot should interpret what the user means by "summarize variant info for each gene" and should be able to come up with a reasonable summary of the variant information for each gene. The chatbot should also be able to interpret the second part of the question "Only select genes that have more than 10 variants. Order the results by the number of variants" and include this in the query. However, there is no "correct" answer to this question, as there are many different ways to summarize the variant information for each gene. The important thing is that the chatbot can come up with a reasonable summary and can explain its reasoning in the answer.

---

# Unanswerable Questions

### These questions test whether the chatbot avoids hallucination:

1. What is the average age of ALS cases? (no age information is available in the table, so this question cannot be answered)
2. Is VAR_id 100 previously reported as pathogenic? (cannot be answered with the data in the table, as there is no information on pathogenicity or previous reports)
3. What is the allele frequency of VAR_id 30 in Europeans? (no population-specific allele frequencies are available in the table, so this question cannot be answered)
4. What is the sex distribution of carriers? (no sex information is available in the table, so this question cannot be answered)
5. Which variants are most important? (important is subjective, so the chatbot should ask for clarification on what the user means by "important")
6. Which variants are both synonymous and high impact? (this is a trick question, as it is not possible for a variant to be both synonymous and high impact. The chatbot should recognize this and explain to the user why this is the case).

It is important that the chatbot recognizes when it cannot answer a question correctly and let the user know
Additionally, if questions are too vague or broad, the chatbot should ask for clarification from the user. 

---

# Advanced Tests (RVAT Required)

These are more advanced benchmarking questions. Only relevant when there is time left and you succeed with the SQLite chatbot.
This will require that the chatbot is familiar with the functions in the rvat package.
It should determine if the question can be answered with SQLite queries or that it requires functions from rvat. If this is the case it should be able to write R code (without hallucinating) execute this and translate the results to an understandable text answer.

## Get the MAF for Moderate Impact variants in TARDBP

```r
buildVarSet(
  object = gdb,
  output = paste0(outdir, "/TARDBP.txt.gz"),
  varSetName = "TARDBP",
  unitTable = "varInfo",
  unitName = "gene_name",
  where = "ModerateImpact = 1"
)
```

---

## How many female carriers are there in the SAS cohort that carry a "pathogenic" mutation in SOD1

```r
buildVarSet(
  object = gdb,
  output = paste0(outdir, "/SOD1.txt.gz"),
  varSetName = "SOD1",
  unitTable = "varInfo",
  unitName = "gene_name",
  where = "HighImpact = 1 OR ModerateImpact = 1"
)
```

**Result:** 9 female carriers in the SAS cohort.

---

