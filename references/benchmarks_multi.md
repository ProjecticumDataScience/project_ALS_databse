# Benchmarks Multi — Multi-table & rvat Extension

This file contains all benchmark questions for the multi-table pipeline.
It includes the base questions (L1-L5, A1-A5, U1-U5, E1-E3) plus new
multi-table and rvat questions (R1-R5).

**Important for grading:**
- `mcp` and `mcp_dual` can answer R questions via multi-table SQL tools in `server.py`
- `ellmer` can answer R questions via registered rvat R tools
- `querychat` **cannot** answer R2, R4, R5 — it is locked to `varInfo_synthetic`.
  A correct refusal explaining this limitation scores TRUE for `grade_answer`.
- Multiple correct approaches exist per question. Accept any approach that produces
  a correct answer and clearly states the method used.

---

# Lookup Queries

## L1 — Select number of variants in NEK1

```sql
SELECT COUNT(VAR_id) AS number_of_variants
FROM varInfo_synthetic
WHERE gene_name = 'NEK1'
```

**Result:** 190 variants.

---

## L2 — Select variants in NEK1 with HighImpact and CADDphred > 20

```sql
SELECT VAR_id, gene_name, HighImpact, CADDphred
FROM varInfo_synthetic
WHERE HighImpact = 1 AND CADDphred > 20 AND gene_name = 'NEK1'
```

**Result:** 13 variants.

---

## L3 — How many variants in TARDBP are predicted deleterious by SIFT?

```sql
SELECT COUNT(*) AS number_of_variants_with_SIFT_D
FROM varInfo_synthetic
WHERE gene_name = 'TARDBP' AND SIFT = 'D'
```

**Result:** 4 variants. SIFT = 'D' means deleterious.

---

## L4 — Which high-impact variants have at least one homozygous ALS patient?

```sql
SELECT VAR_id, gene_name, HighImpact, ALS_1, ALS_2, ALS_3, ALS_4, ALS_5
FROM varInfo_synthetic
WHERE HighImpact = 1 AND (ALS_1 = 2 OR ALS_2 = 2 OR ALS_3 = 2 OR ALS_4 = 2 OR ALS_5 = 2)
```

**Result:** 102 variants have at least one homozygous ALS carrier.

---

## L5 — What are the ten most deleterious variants in ABCA4?

```sql
SELECT VAR_id, gene_name, CADDphred, SIFT, PolyPhen
FROM varInfo_synthetic
WHERE CADDphred > 20 AND SIFT = 'D' AND PolyPhen = 'D' AND gene_name = 'ABCA4'
ORDER BY CADDphred DESC
LIMIT 10
```

**Note:** "Most deleterious" is ambiguous. The chatbot should state which metric
it uses (CADDphred, SIFT, PolyPhen, or a combination) before answering.

---

# Analytical Queries

## A1 — What is the variant with the highest allele frequency?

```sql
SELECT VAR_id, MAX(AF) AS highest_allele_frequency
FROM varInfo_synthetic
```

**Result:** VAR_id 901 has the highest AF (9.68148e-05).

---

## A2 — What is the average allele frequency for synonymous, moderate, and high-impact variants separately?

```sql
SELECT
  AVG(CASE WHEN Synonymous = 1 THEN AF END) AS average_AF_synonymous,
  AVG(CASE WHEN ModerateImpact = 1 THEN AF END) AS average_AF_moderate,
  AVG(CASE WHEN HighImpact = 1 THEN AF END) AS average_AF_high
FROM varInfo_synthetic
```

**Note:** Must use CASE WHEN to compute separate averages — not AND conditions.

---

## A3 — How many high-impact variants does ALS_1 carry?

```sql
SELECT
  SUM(CASE WHEN ALS_1 = 1 THEN 1 ELSE 0 END) AS heterozygous,
  SUM(CASE WHEN ALS_1 = 2 THEN 1 ELSE 0 END) AS homozygous
FROM varInfo_synthetic
WHERE HighImpact = 1
```

**Result:** 42 heterozygous and 33 homozygous variants. Total carriers = 75.

---

## A4 — What is the total burden of cases versus controls?

```sql
SELECT
  SUM(ALS_1 + ALS_2 + ALS_3 + ALS_4 + ALS_5) AS total_cases_burden,
  SUM(Control_1 + Control_2 + Control_3 + Control_4 + Control_5) AS total_controls_burden
FROM varInfo_synthetic
```

**Result:** Cases = 9083, Controls = 8974.

---

## A5 — Are there more variants in cases than controls?

```sql
SELECT
  VAR_id, gene_name,
  (ALS_1 + ALS_2 + ALS_3 + ALS_4 + ALS_5) AS case_count,
  (Control_1 + Control_2 + Control_3 + Control_4 + Control_5) AS control_count,
  ((ALS_1 + ALS_2 + ALS_3 + ALS_4 + ALS_5) * 1.0) /
  NULLIF((Control_1 + Control_2 + Control_3 + Control_4 + Control_5), 0) AS case_control_ratio
FROM varInfo_synthetic
ORDER BY case_control_ratio DESC
LIMIT 10
```

**Note:** This can be interpreted differently. The chatbot should state its
interpretation and provide a reasonable answer based on the data.

---

# Unanswerable Questions

These test whether the chatbot avoids hallucination. The chatbot should recognise
when it cannot answer and explain why.

1. **U1** — What is the average age of ALS cases? (no age column in varInfo_synthetic)
2. **U2** — Is VAR_id 100 previously reported as pathogenic? (no pathogenicity column)
3. **U3** — What is the allele frequency of VAR_id 30 in Europeans? (no population-specific AF)
4. **U4** — Which variants are most important? (ambiguous — ask for clarification)
5. **U5** — Which variants are both synonymous and high impact? (mutually exclusive — explain why)

---

# Expert Queries

## E1 — Are moderate and high-impact mutations in TARDBP enriched in cases vs controls?

**Interpretation 1 — variant count:**
```sql
SELECT
  (SELECT COUNT(*) FROM varInfo_synthetic
   WHERE gene_name = 'TARDBP' AND (ModerateImpact=1 OR HighImpact=1)
   AND (ALS_1!=0 OR ALS_2!=0 OR ALS_3!=0 OR ALS_4!=0 OR ALS_5!=0)) AS n_ALS,
  (SELECT COUNT(*) FROM varInfo_synthetic
   WHERE gene_name = 'TARDBP' AND (ModerateImpact=1 OR HighImpact=1)
   AND (Control_1!=0 OR Control_2!=0 OR Control_3!=0 OR Control_4!=0 OR Control_5!=0)) AS n_control
```
**Answer:** 15 variants in both ALS and controls.

**Interpretation 2 — burden:**
```sql
SELECT
  SUM(ALS_1+ALS_2+ALS_3+ALS_4+ALS_5) AS ALS_burden,
  SUM(Control_1+Control_2+Control_3+Control_4+Control_5) AS Control_burden
FROM varInfo_synthetic
WHERE gene_name = 'TARDBP' AND (ModerateImpact=1 OR HighImpact=1)
```
**Answer:** ALS burden = 80, control burden = 85.

Both interpretations are valid. The chatbot must state which it uses.

---

## E2 — In which gene does ALS_1 have the most pathogenic mutations?

```sql
WITH pathogenic AS (
  SELECT gene_name, ALS_1
  FROM varInfo_synthetic
  WHERE ALS_1 != 0
    AND (CADDphred > 20 OR PolyPhen = 'D' OR SIFT = 'D')
)
SELECT gene_name, SUM(ALS_1) AS total_pathogenic_mutations
FROM pathogenic
GROUP BY gene_name
ORDER BY total_pathogenic_mutations DESC
```

**Answer:** ABCA4 with 321 (allele count: homozygous = 2, heterozygous = 1).

---

## E3 — In which genes are more variants present in cases than controls, and what is the ratio?

```sql
SELECT
  gene_name,
  SUM(ALS_1+ALS_2+ALS_3+ALS_4+ALS_5) AS case_dosage,
  SUM(Control_1+Control_2+Control_3+Control_4+Control_5) AS control_dosage,
  (SUM(ALS_1+ALS_2+ALS_3+ALS_4+ALS_5) + 1.0) /
  (SUM(Control_1+Control_2+Control_3+Control_4+Control_5) + 1.0) AS dosage_ratio
FROM varInfo_synthetic
GROUP BY gene_name
ORDER BY dosage_ratio DESC
```

**Answer:** TARDBP, PEX5, ABCA4, SOD1, and IL3RA have more case carriers than controls.

---

# Multi-table / rvat Questions

## R1 — What is the MAF for moderate impact variants in TARDBP?

**Key concept:** MAF = MIN(AF, 1-AF). Answerable via SQL alone.

**SQL approach:**
```sql
SELECT VAR_id, gene_name, AF,
       CASE WHEN CAST(AF AS REAL) <= 0.5
            THEN CAST(AF AS REAL)
            ELSE 1 - CAST(AF AS REAL)
       END AS MAF
FROM varInfo_synthetic
WHERE gene_name = 'TARDBP'
  AND ModerateImpact = 1
  AND AF != '.'
ORDER BY MAF DESC
```

**rvat approach:**
```r
buildVarSet(
  object     = gdb,
  output     = paste0(outdir, "/TARDBP_moderate.txt.gz"),
  varSetName = "TARDBP",
  unitTable  = "varInfo",
  unitName   = "gene_name",
  where      = "ModerateImpact = 1"
)
```

**Grading:** Accept any answer that correctly defines MAF, filters to TARDBP
ModerateImpact variants, and returns plausible values.

---

## R2 — How many female carriers are there in the SAS cohort that carry a pathogenic mutation in SOD1?

**Tables needed:** `varInfo_synthetic` + `pheno` (IID, sex, pop, superPop)

**Key challenge:** The genotype columns (ALS_1..ALS_5, Control_1..Control_5) do not
directly link to sample IDs in the pheno table — this join requires rvat or
knowledge of the sample ID mapping.

**rvat approach:**
```r
buildVarSet(
  object     = gdb,
  output     = paste0(outdir, "/SOD1.txt.gz"),
  varSetName = "SOD1",
  unitTable  = "varInfo",
  unitName   = "gene_name",
  where      = "HighImpact = 1 OR ModerateImpact = 1"
)
```

**Answer:** 9 female carriers in the SAS cohort.

**Grading:** A correct refusal that explains the sample ID mapping problem
scores TRUE for grade_answer. rvat returning 9 is fully correct.

---

## R4 — What is the sex distribution of variant carriers in the dataset?

**Tables needed:** `SM` (IID, sex) or `pheno` (IID, sex, pheno, pop, superPop)

**SQL approach (multi-table backends):**
```sql
SELECT sex, COUNT(*) AS n_samples
FROM SM
GROUP BY sex
```

**Grading:** Award TRUE for grade_answer for either:
- A correct query against SM/pheno returning sex counts
- A correct refusal explaining that varInfo_synthetic has no sex column
  and naming where the data is (SM or pheno table)

---

## R5 — Which population has the highest number of high-impact variant carriers?

**Tables needed:** `varInfo_synthetic` + `pheno` (IID, pop, superPop)

**Key challenge:** Same sample ID mapping problem as R2. The genotype columns
do not directly link to pheno table IDs without rvat.

**Grading:** A correct refusal identifying the join limitation is acceptable.
A population-level breakdown using rvat or a creative SQL approach scores full marks.

---

# Grading Summary

| ID | Category | Answerable via SQL alone? | Needs pheno/SM join? | querychat? |
|----|----------|--------------------------|----------------------|------------|
| L1-L5 | Lookup | Yes | No | Yes |
| A1-A5 | Analytical | Yes | No | Yes |
| U1-U5 | Unanswerable | Refuse | No | Yes |
| E1-E3 | Expert | Yes (complex SQL) | No | Partially |
| R1 | rvat | Yes | No | No (locked to varInfo_synthetic) |
| R2 | rvat | Partial | Yes | No |
| R4 | rvat | Yes (SM table) | Yes | No |
| R5 | rvat | Partial | Yes | No |

**Note:** R3 is omitted — it is equivalent to A5/gene summary already covered
in the base benchmark.
