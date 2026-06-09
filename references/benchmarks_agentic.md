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
| U01 | VAR_id 100 pathogenic? | No ClinVar data. CADD alone ≠ pathogenic. |
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

# Complexity routing expectations

| Category | Classifier | Pipeline |
|----------|------------|----------|
| simple (S) | "simple" | single/dual shot |
| analytical (A) | "simple" | single/dual shot |
| complex (C) | "simple" | single/dual shot |
| phenotype (P) | "complex" (sex/population keywords) | agentic loop |
| annotation_trap (T) | "simple" | single/dual shot |
| unanswerable (U) | "simple" | single/dual shot |