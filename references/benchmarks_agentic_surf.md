# Benchmarks Agentic — Ground Truth (Full Question Set)

**Database:** rvatData.gdb — varInfo_synthetic (1802 variants, 12 genes)
**Missing values:** stored as '.' not NULL
**IID mapping:** ALS_1 → 'ALS1' in pheno (remove underscore)
**Sex coding:** 1=female, 2=male | **Pheno coding:** 1=ALS, 2=control
**HighImpact/ModerateImpact/Synonymous:** stored as TEXT '0'/'1'

---

# SIMPLE (S01–S16)

| ID | Question | Answer | Tool |
|----|----------|--------|------|
| S01 | SOD1 PolyPhen=D | **23** (NOT 28 — verified directly from database) | count/run_variant_query |
| S02 | Unique chromosomes | **10**: chr1,chr4,chr9,chr10,chr12,chr14,chr15,chr16,chr21,chrX | run_variant_query |
| S03 | ABCA4 CADD>30 | **34** | get_high_impact_variants_in_gene or run_variant_query |
| S04 | Synonymous total | **533** | count_variants_by_impact |
| S05 | OPTN variants | **121** | count_variants_in_gene |
| S06 | chrX HighImpact | **14** | run_variant_query |
| S07 | SIFT=D AND PolyPhen=D | **343** | run_variant_query |
| S08 | ALS_2 homozygous (ALS_2=2) | **606** | run_variant_query |
| S09 | Distinct genes | **12** | get_database_info or run_variant_query |
| S10 | Total variants | **1802** | get_database_info |
| S11 | Variants per gene (ranked) | ABCA4=589, RIN3=222, NEK1=190, IL3RA=147, PEX5=124, OPTN=121, ZNF483=113, FUS=95, CYP19A1=89, SOD1=49, UBQLN2=36, TARDBP=27 | summarize_variants_by_gene |
| S12 | Missing CADD | **607** (33.68%) | run_variant_query |
| S13 | All 3 annotations present | **1131** | run_variant_query |
| S14 | ABCA4 HighImpact | **44** | count_variants_in_gene + filter |
| S15 | AF exactly zero | **36** | run_variant_query |
| S16 | OPTN SIFT=D | **28** | count_sift_deleterious_in_gene |

**Note S01:** File states 28, actual database value is **23**. Use 23.

---

# ANALYTICAL (A01–A17)

| ID | Question | Answer |
|----|----------|--------|
| A01 | Lowest non-zero AF in NEK1 | VAR_id 1325,1327,1333,1348,1402 — all AF=2×10⁻⁵ |
| A02 | % high impact | **6.77%** (122/1802) |
| A03 | High:synonymous ratio per gene (≥5 each) | NEK1=0.647, IL3RA=0.371, ABCA4=0.270, OPTN=0.262, PEX5=0.178 |
| A04 | Highest control high-impact burden | **Control_2=134** (C1=119, C3=133, C4=124, C5=113) |
| A05 | Avg CADD deleterious vs benign | Both D+D: **26.04** (n=343) vs both T+B: **12.02** (n=403) |
| A06 | Avg AF per chromosome, highest | Highest: **chr10** (0.002649), then chr1 (0.002551) |
| A07 | SOD1 burden cases vs controls | Cases=**248**, Controls=**247** |
| A08 | % variants carried by ≥1 ALS patient | **99.61%** |
| A09 | Avg CADD high vs moderate NEK1 | High=**36.31**, Moderate=**20.10** |
| A10 | Control-only variants | **7** |
| A11 | SOD1 impact distribution | High=4, Moderate=38, Synonymous=7, Total=49 |
| A12 | Chromosome with most variants | **chr1** (616), then chr14 (222), chr4 (190), chrX (183) |
| A13 | % missing all 3 annotations | **33.68%** (607/1802) |
| A14 | ALS_4 high-impact het/hom | Heterozygous=**33**, Homozygous=**41** |
| A15 | Avg CADD moderate-impact PEX5 | **23.41** |
| A16 | ALS_5 vs Control_5 high-impact burden | ALS_5=**117**, Control_5=**113** |
| A17 | UBQLN2 summary | Total=36, High=1, Moderate=24, Synonymous=11, mean_AF=0.000386 |

---

# COMPLEX (C01–C18)

| ID | Question | Answer |
|----|----------|--------|
| C01 | ALS-only variants | **10** |
| C02 | Gene with greatest case-control burden diff | **ABCA4** (diff=83), then PEX5 (45), NEK1 (21), TARDBP (14) |
| C03 | High-impact per ALS patient in TARDBP/SOD1/NEK1 | ALS_1=22, ALS_2=28, ALS_3=26, ALS_4=21, ALS_5=24 |
| C04 | Most homozygous ALS calls per gene | ABCA4=993, RIN3=356, NEK1=301, IL3RA=261, PEX5=227 |
| C05 | Shared all 10 individuals | **29** |
| C06 | TARDBP moderate+high burden per individual | Cases: ALS_1=12, ALS_2=14, ALS_3=21, ALS_4=18, ALS_5=15. Controls: C1=15, C2=17, C3=20, C4=14, C5=19 |
| C07 | Variants in all 10 individuals | 29 variants; e.g. VAR_id 65, 99, 231, 303... mostly ABCA4 |
| C08 | SIFT=D top 3 genes case burden | ABCA4 (cases=984, ctrl=874), RIN3 (364 vs 365), NEK1 (345 vs 344) |
| C09 | Impact category counts | High=122, Moderate=1147, Synonymous=533, Other=0 |
| C10 | Genes where ALS_3 carries ≥1 high-impact | **11 genes**: ABCA4,CYP19A1,IL3RA,NEK1,OPTN,PEX5,RIN3,SOD1,TARDBP,UBQLN2,ZNF483 |
| C11 | FUS summary | Total=95, High=1, Moderate=55, Synonymous=39, mean_AF=0.000102 |
| C12 | CADD bins case burden | <10: n=225 burden=1144; 10-20: n=250 burden=1230; 20-30: n=627 burden=3183; ≥30: n=93 burden=468 |
| C13 | PolyPhen dist among high-impact | Missing('.')=106, D=6, B=6, P=4 |
| C14 | Top 3 highest CADD | VAR_id 90 (ABCA4, CADD=50), VAR_id 802 (PEX5, CADD=50), VAR_id 33 (ABCA4, CADD=47) |
| C15 | Top 3 lowest non-zero AF | VAR_id 3 (TARDBP), VAR_id 20 (TARDBP), VAR_id 31 (ABCA4) — all AF=2×10⁻⁵ |
| C16 | Only high-impact FUS variant | VAR_id 1175, pos 31180233 — CADD/PolyPhen/SIFT all missing ('.') |
| C17 | IL3RA chromosome + proportion | chrX; chrX has 183 variants (10.2% of total); IL3RA has 147/183 (80.3%) |
| C18 | RIN3 high-impact burden | Cases=**7**, Controls=**9** — controls slightly higher |

---

# PHENOTYPE (P01–P06)

| ID | Question | Answer | Expected tool |
|----|----------|--------|---------------|
| P01 | Female carriers ABCA4 | **2** — ALS3 (EUR/TSI, age~54), ALS5 (AFR/MSL, age~59) | get_carriers_with_phenotype gene=ABCA4 sex=1 |
| P02 | Female carriers SOD1 | **2** — ALS3 and ALS5 | get_carriers_with_phenotype gene=SOD1 sex=1 |
| P03 | SAS carriers NEK1 | **2** — ALS1 (PJL, male), ALS2 (BEB, male) | get_carriers_with_phenotype gene=NEK1 population=SAS |
| P04 | Sex distribution | **12865 female**, 12135 male, total 25000 | get_sex_distribution |
| P05 | Average age ALS cases | **~60.1 years** — IS answerable, do NOT refuse | get_age_distribution |
| P06 | ALS cases vs controls | **5000 ALS**, 20000 controls | get_database_info |

**Critical grading notes:**
- P01/P02: n_qualifying_variants (284/286) is NOT the carrier count. Number of carriers = number of rows (2).
- P05: This IS answerable. grade_answer=FALSE if model refuses.
- P06: grade_answer=FALSE if model says 0 controls.

---

# ANNOTATION TRAPS (T01–T03)

| ID | Question | Answer | Trap |
|----|----------|--------|------|
| T01 | PolyPhen "possibly damaging" | **182** (PolyPhen='P') | Must query PolyPhen='P' not text 'possibly damaging' |
| T02 | SIFT "tolerated" | **565** (SIFT='T') | Must query SIFT='T' not 'tolerated' or 'B' |
| T03 | HighImpact=1 AND Synonymous=1 | **0** — mutually exclusive | Must explain biological impossibility |

---

# UNANSWERABLE (U01–U15)

All should call get_database_limitations. Model must NOT hallucinate.

| ID | Question | Why unanswerable |
|----|----------|-----------------|
| U01 | VAR_id 100 pathogenic? | VAR_id 100 = ABCA4 rs760098992. ClinVar record: **not in ClinVar**. Correct answer: unknown/no ClinVar record. |
| U02 | AF of VAR_id 30 in Europeans? | Global AF only. No population-specific AF. |
| U03 | Synonymous AND high-impact? | Mutually exclusive — 0 exist. Correct answer is "0, impossible" not a refusal. |
| U04 | Protein domain of VAR_id 42? | No protein domain annotation. |
| U05 | Wet-lab validation? | No experimental data. |
| U06 | Earliest age of onset? | No clinical onset data. |
| U07 | LD between VAR_id 10 and 11? | No haplotype/phase data. |
| U08 | Clinically significant variants? | Too vague + no ClinVar. Ask for clarification. |
| U09 | rs-number of VAR_id 200? | Synthetic dataset — no valid rs-numbers. |
| U10 | De novo mutations? | No parental data. |
| U11 | AF of VAR_id 50 in African population? | Global AF only. |
| U12 | How long ALS_3 diagnosed? | No clinical timeline data. |
| U13 | Strongest effect on disease risk? | Requires statistical association not in table. |
| U14 | Most severe disease progression? | No clinical progression data. |
| U15 | Variant at chrX:1378764 causative? | Cannot infer causality from CADD/PolyPhen alone. |

**Note U03:** Unlike other unanswerables, querying this actually returns 0 — which IS the correct answer. Accept both "0 variants exist" and an explanation of mutual exclusivity.

---

# RVAT Statistical Tests (R01–R05)

These questions require the rvat_analysis MCP server (plumber on port 8009).
They test real statistical burden testing, MAF computation, LD, and single
variant association — capabilities beyond what SQL alone can provide.

**Important:** grade_answer=TRUE if the model calls the correct rvat tool
and interprets the result correctly. Exact numeric answers may vary slightly
due to floating point but should be in the right order of magnitude.

---

## R01 — Run a burden test for SOD1 in ALS cases versus controls

**Expected tool:** rvat_analysis/run_burden_test
**Params:** {gene: "SOD1", test: "firth", impact_filter: "high_moderate"}

**Answer:**
- P-value ≈ 0 (highly significant)
- OR ≈ 5.9 (strong case enrichment)
- 42 variants tested, 80 case carriers vs 53 control carriers
- Interpretation: SOD1 shows highly significant rare variant burden in ALS

**Grading:** grade_answer=TRUE if response states significant association
(P<0.05) with OR>1 for SOD1. grade_tool=TRUE if run_burden_test called.

---

## R02 — Get the MAF for moderate impact variants in TARDBP

**Expected tool:** rvat_analysis/get_maf_by_impact
**Params:** {gene: "TARDBP", impact_filter: "moderate"}

**Answer:**
- Mean MAF ≈ 0.0001 (0.01%) across ~14 moderate impact variants
- All variants are rare (MAF < 0.001)
- SUMMARY row contains mean MAF for the gene

**Grading:** grade_answer=TRUE if response states MAF ~0.0001 or describes
variants as rare. grade_tool=TRUE if get_maf_by_impact called with moderate.
grade_answer=FALSE if model uses get_average_af_by_impact (global averages).

---

## R03 — How many female carriers are there in the SAS cohort that carry a pathogenic mutation in SOD1?

**Expected tool:** rvat_analysis/get_carrier_count_filtered
**Params:** {gene: "SOD1", impact_filter: "high_moderate", sex: 1, population: "SAS", phenotype: 1}

**Answer:** **9 unique female ALS-case carriers** in the SAS cohort with a
high+moderate impact ("pathogenic" proxy) variant in SOD1, counted against
the full 25,000-sample rvat cohort (not the 10-sample synthetic genotype
table). "Pathogenic mutation" = high+moderate impact variants. "Carrier"
in a disease context implicitly means ALS cases (phenotype=1).

**Grading:** grade_answer=TRUE if response states 9 carriers and used the
real rvat cohort (get_carrier_count_filtered or equivalent), not the
synthetic 10-sample get_carriers_with_phenotype tool.
grade_answer=FALSE if model reports a number bounded by 10 total samples
(a sign it queried the synthetic subset instead of the real cohort).

---

## R04 — What is the linkage disequilibrium between high-impact variants in FUS?

**Expected tool:** rvat_analysis/get_ld_matrix
**Params:** {gene: "FUS", impact_filter: "high"}

**Answer:** FUS has only 1 high-impact variant (VAR_id 1175). LD cannot be
computed with fewer than 2 variants. The tool returns an informative message:
"Fewer than 2 variants — LD cannot be computed".

**Grading:** grade_answer=TRUE if model calls get_ld_matrix AND correctly
reports that LD cannot be computed (only 1 high-impact variant in FUS).
grade_answer=FALSE if model refuses entirely or hallucinates LD values.
grade_tool=TRUE if get_ld_matrix was called.

---

## R05 — What are the most significant single variants in NEK1 associated with ALS?

**Expected tool:** rvat_analysis/run_single_variant_test
**Params:** {gene: "NEK1", test: "scoreSPA", impact_filter: "any"}

**Answer:** Per-variant p-values for all NEK1 variants. Top variants by CADD
include VAR_id 1331 and 1449 (both CADD=41). P-values will vary — the key is
that the model runs single variant tests and reports the top results.

**Note:** With only 5 cases and 5 controls in the synthetic genotype data,
individual variant p-values may not be very significant. Accept any reasonable
ranking by p-value or CADD score.

**Grading:** grade_answer=TRUE if run_single_variant_test called and model
reports top variants with p-values or effect sizes.
grade_tool=TRUE if run_single_variant_test was called.

---

# NONSENSE (N01–N16)

These questions test whether the model correctly refuses, corrects, or clarifies
non-standard inputs: missing annotations, biological impossibilities, vague requests,
and pure gibberish.

## Category 1 — Missing annotation (N01–N05)

| ID | Question | Why unanswerable | Expected answer |
|----|----------|-----------------|-----------------|
| N01 | What is the ClinVar pathogenicity classification of VAR_id 42? | No ClinVar column or external annotation present. SIFT/PolyPhen/CADD are computational predictions, not clinical classifications. | "This information is not available in the database." |
| N02 | What is the gnomAD allele frequency of the variant at position 1378764 on chrX in the European population? | No gnomAD data present. The AF column is global and synthetic — no population-specific or external sources. | "No gnomAD or population-specific AF available." |
| N03 | Which exon does the high-impact variant in FUS (VAR_id 1175) affect? | No exon annotation present in varInfo_synthetic. Only chromosome and position are known. | "Exon information is not present in the database." |
| N04 | What is the protein domain affected by the most deleterious variant in SOD1? | No protein domain annotation. The database contains only genomic position, no protein structure information. | "Protein domain data is not available." |
| N05 | Does VAR_id 200 affect splicing? | No splicing annotation (e.g. SpliceAI) present. HighImpact may include splicing variants but provides no specific splicing score. | "Splicing predictions are not present in the database." |

## Category 2 — Biologically or logically impossible (N06–N10)

| ID | Question | Why impossible | Expected answer |
|----|----------|---------------|-----------------|
| N06 | Which variants are both synonymous and high impact? | Biologically impossible: a synonymous variant does not change the amino acid and cannot by definition be high-impact. COUNT(*) WHERE HighImpact=1 AND Synonymous=1 = 0. | "This is biologically impossible — the categories are mutually exclusive. There are 0 such variants in the dataset." |
| N07 | Which variants have a genotype of 3 (i.e. three copies of the alternate allele) in ALS_1? | Genotype coding is 0/1/2 (diploid). Genotype 3 does not exist in a diploid organism. There are 0 rows with ALS_1=3. | "Genotype 3 does not exist — coding is 0=hom-ref, 1=het, 2=hom-alt." |
| N08 | What is the allele frequency of a variant that no one in the world carries? | If nobody carries a variant, the allele frequency is by definition 0 — the question answers itself. Additionally, variants with AF=0 are already present (n=36). | "AF = 0 by definition. The question is circular." |
| N09 | How many variants have a CADD score of exactly 0 and are also high impact? | A CADD score of 0 implies no deleterious effect — this is by definition incompatible with high-impact classification. No high-impact variants with CADD=0 exist in the data. | "The combination CADD=0 AND HighImpact=1 does not exist in this dataset and is biologically contradictory." |
| N10 | Which ALS patient is also listed as a control? | In varInfo_synthetic, ALS_1–5 and Control_1–5 are separate columns for different individuals. The same person cannot be in both groups. In the pheno table, each IID has exactly one phenotype. | "Cases and controls are separate individuals — overlap is not possible in this study design." |

## Category 3 — Too vague to answer (N11–N15)

| ID | Question | Why unanswerable | Expected answer |
|----|----------|-----------------|-----------------|
| N11 | Which variants are important? | "Important" is subjective and context-dependent: clinical, statistical, functional, rare? Without a definition the question cannot be answered. | Ask for clarification — does the user mean high CADD score? Significant burden? Rare variants? Clinical relevance? |
| N12 | Is NEK1 an ALS gene? | This is a biological/literature question, not a database question. The database contains no publication status, association scores, or external literature references. A burden test via the rvat server can calculate association, but cannot prove causality. | "The database contains no information about gene status in the literature. A burden test via the rvat server can calculate association, but cannot prove causality." |
| N13 | What is the most interesting variant in the dataset? | "Interesting" is entirely subjective. The model should not select a variant without asking what the user means. | Ask for clarification — rarest? Highest CADD? Most case-specific? Most contradictory annotations? |
| N14 | Which variants should we follow up on in the wet lab? | Wet lab prioritisation requires clinical expertise, literature knowledge, and experimental considerations not present in the database. The model can suggest criteria but must not make the decision itself. | "This requires clinical assessment outside the database. I can filter variants by criteria you specify, but cannot determine wet lab priority myself." |
| N15 | Is this dataset good enough to find the cause of ALS? | This is a scientific and statistical judgement question the model cannot answer from data alone. It requires knowledge of study design, statistical power, confounders, and the current scientific literature. | "This is a methodological question outside the scope of the database. I can report statistics (n=5 cases, 5 controls in the synthetic dataset) but cannot make statements about causality or sufficient power." |

## Category 4 — Pure nonsense / gibberish (N16)

| ID | Question | Why unanswerable | Expected answer |
|----|----------|-----------------|-----------------|
| N16 | jasdkjahdkjahdas | Random characters with no recognisable words and no dataset keywords. Not a coherent question of any kind. Should be caught by the nonsense gate before any tool/LLM reasoning call is made. | "That doesn't look like a question I can help with. Please ask something about the ALS variant database." |

**Grading notes for nonsense questions:**
- N06, N07, N09: grade_answer=TRUE if the model queries the database and correctly returns 0, OR explains why the combination is impossible.
- N08: grade_answer=TRUE if model explains the circularity (AF=0 by definition).
- N10: grade_answer=TRUE if model explains case/control separation without querying.
- N11, N13, N14: grade_answer=TRUE if model asks for clarification rather than guessing.
- N12, N15: grade_answer=TRUE if model explains limitation and optionally offers what it *can* do (run burden test, report n).
- N01–N05: grade_answer=FALSE if model hallucinates an annotation value.
- N16: grade_answer=TRUE if model recognises this as nonsense and declines without attempting interpretation or guessing intent. Should ideally trigger immediately (no tool call) via the nonsense gate.

---

# TOOLFREE (F01–F15)

These questions are answerable purely via SQL on varInfo_synthetic and/or pheno,
without requiring any MCP tool beyond run_variant_query. They test whether the
model can construct complex SQL correctly without tool scaffolding.

## Variant-level SQL (F01–F10)

| ID | Question | Answer | SQL hint |
|----|----------|--------|----------|
| F01 | For how many variants is the total allele count higher in ALS cases than in controls? | **792** | SUM(ALS_1..5) > SUM(Control_1..5) per variant |
| F02 | Which gene has the highest proportion of high-impact variants relative to its total variant count? | **NEK1 (17.37%)** › OPTN (9.09%) › IL3RA (8.84%) › SOD1 (8.16%) › ABCA4 (7.47%). Trap: ABCA4 has the most high-impact in absolute numbers but not proportionally. | GROUP BY gene_name, ROUND(100.0 * SUM(HighImpact=1) / COUNT(*), 2) |
| F03 | How many variants are carried (het or hom) by at least 3 of the 5 ALS patients? | **1425** | CASE WHEN ALS_x > 0 THEN 1 ELSE 0 END per patient, sum ≥ 3 |
| F04 | What is the average CADD score of high-impact variants per chromosome? Which chromosome has the highest? | chr12 (37.16, n=5) › chr4/NEK1 (36.31, n=13) › chr10/OPTN (36.29, n=7). chrX has lowest: 26.55 (n=12) | WHERE HighImpact=1 AND CADDphred != '.', GROUP BY CHROM, AVG(CAST(...)) |
| F05 | What is the total number of alleles carried by each individual ALS patient across all variants? | ALS_1=1828, ALS_2=1817, ALS_3=1793, ALS_4=1880, ALS_5=1765. ALS_4 carries the most total alleles. | SUM(ALS_1), SUM(ALS_2)... — no WHERE filter |
| F06 | How many variants are homozygous (genotype=2) in ALL five ALS patients simultaneously? | **11** | WHERE ALS_1=2 AND ALS_2=2 AND ALS_3=2 AND ALS_4=2 AND ALS_5=2 |
| F07 | Does a higher CADD score correlate with a higher rate of PolyPhen "damaging" (D) predictions? Show this using CADD bins. | CADD <15: 3.6% PolyPhen=D — CADD 15–25: 29.2% — CADD ≥25: 72.3%. Strong positive correlation. Trap: model must define bins and explain. | CASE WHEN CAST(CADDphred AS REAL) < 15 / <25 / ≥25, then % PolyPhen=D per bin |
| F08 | How many variants are carried by exactly one ALS patient and by no control at all ("private" ALS variants)? | **1** — surprisingly low; model must not correct toward a "more plausible" number. | sum of ALS carriers = 1, all Controls = 0 |
| F09 | Which ALS patient has the most "private" variants — carried only by that patient and no one else in the dataset? | **ALS_3** has 1 private variant. ALS_1, ALS_2, ALS_4, ALS_5 each have 0. Trap: more total alleles ≠ more private variants. | For each patient: ALS_x > 0 AND all other ALS = 0 AND all Controls = 0 |
| F10 | For high-impact variants only, what is the case-to-control burden ratio per gene? Which genes show enrichment in cases? | Enriched in cases (ratio >1): CYP19A1 (1.53), PEX5 (1.38), UBQLN2 (1.15), ABCA4 (1.01). Enriched in controls: ZNF483 (0.33), SOD1 (0.73), OPTN (0.78). Trap: must use pseudo-counts or NULLIF to avoid division by zero, and note low n per gene. | (SUM cases + 0.5) / (SUM controls + 0.5) as pseudo-count |

## Pheno table queries (F11–F13)

| ID | Question | Answer | SQL hint |
|----|----------|--------|----------|
| F11 | What is the mean age of ALS cases per super-population? Which population is oldest on average? | AFR (60.44) › EAS (60.30) › SAS (60.16) › AMR (59.82) › EUR (59.64). Small differences — model should note this. | FROM pheno WHERE pheno=1 AND age IS NOT NULL, GROUP BY superPop |
| F12 | How many female ALS cases are there in the South Asian (SAS) population? | **576** | FROM pheno WHERE pheno=1 AND superPop='SAS' AND CAST(sex AS INT)=1. Trap: sex=1=female, pheno=1=ALS |
| F13 | What is the sex, population, and age of each of the five named ALS patients (ALS1–ALS5) from the pheno table? | ALS1: Male/SAS/66yr — ALS2: Male/SAS/67yr — ALS3: Female/EUR/54yr — ALS4: Male/AFR/65yr — ALS5: Female/AFR/59yr. Trap: requires a query on the pheno table, not varInfo_synthetic. | FROM pheno WHERE IID IN ('ALS1','ALS2','ALS3','ALS4','ALS5') |

## Edge cases (F14–F15)

| ID | Question | Answer | Notes |
|----|----------|--------|-------|
| F14 | How many variants have contradictory functional predictions — deleterious by SIFT but benign by PolyPhen? Which genes have the most? | Total: **122** variants with SIFT=D AND PolyPhen=B. Top genes: ABCA4 (43), RIN3 (16), ZNF483 (12), NEK1 (10), PEX5 (9). Trap: contradictory predictions are NOT wrong or unanswerable — they are biologically possible and valuable as QC. Model must explain this, not refuse. | WHERE SIFT='D' AND PolyPhen='B' |
| F15 | How many variants have an allele frequency above the dataset average? Use a subquery. | **58** variants are above the mean AF (0.001584). Only 3.2% of all variants — distribution is strongly right-skewed. Trap: AF='.' must be excluded from both the subquery and outer query. | Subquery for AVG(CAST(AF AS REAL)) WHERE AF != '.', then outer query WHERE CAST(AF AS REAL) > that value |

**Grading notes for toolfree questions:**
- F02: grade_answer=FALSE if model names ABCA4 as the answer (absolute vs proportional confusion).
- F07: grade_answer=TRUE only if model defines bins explicitly and shows per-bin percentages.
- F08, F09: grade_answer=FALSE if model "corrects" a surprising low number to something more expected.
- F10: grade_answer=FALSE if model divides by zero or omits a gene due to zero control burden.
- F12: grade_answer=FALSE if model uses sex=2 for female or pheno=2 for ALS.
- F14: grade_answer=FALSE if model refuses as unanswerable or calls the contradictions "errors".
- F15: grade_answer=FALSE if model includes AF='.' rows in either part of the query.

---

# Complexity routing expectations

| Category | Classifier | Pipeline |
|----------|------------|----------|
| simple (S) | "simple" | single/dual shot |
| analytical (A) | "simple" | single/dual shot |
| complex (C) | "simple" | single/dual shot |
| phenotype (P) | "complex" (sex/population keywords) | agentic loop |
| annotation_trap (T) | "simple" | single/dual shot |
| unanswerable (U) | "simple" | single/dual shot |
| nonsense (N) | "simple" | single/dual shot |
| toolfree (F) | "simple" | single/dual shot |
| rvat (R) | "complex" (statistical test keywords) | agentic loop |

---

# Updated Grading Summary (with rvat, nonsense, toolfree)

| Category | Count | Key grading principle |
|----------|-------|-----------------------|
| simple (S) | 16 | Exact numeric match |
| analytical (A) | 17 | Numeric match + correct reasoning |
| complex (C) | 18 | Multi-step SQL, correct aggregation |
| phenotype (P) | 6 | Carrier count ≠ variant count; P05 IS answerable |
| annotation_trap (T) | 3 | Must use raw coded values (D/P/T/B), not plain text |
| unanswerable (U) | 15 | Must refuse + explain; U03 accepts "0" as correct |
| nonsense (N) | 16 | Refuse impossible, clarify vague, return 0 for biological contradictions, decline pure gibberish |
| toolfree (F) | 15 | Complex SQL correctness; traps around absolute vs proportional, pseudo-counts, coding |
| rvat (R) | 5 | Correct tool call + correct interpretation of statistical output |
| **Total** | **111** | |