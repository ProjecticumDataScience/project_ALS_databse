library(ellmer)
library(querychat)
library(rollama)

# create the ollama client
ollama_client <- chat_ollama(
  model = "llama3.1:8b",
  params = params(
    temperature = 0.1,    # less creative, more focused/deterministic
    num_predict = 200     # limits response length, prevents rambling
  )
)

# connect to the database
gdb <- gdb(rvat_example("rvatData.gdb"))

# data description setup
data_description <- "
Genomic variant data from Project MinE ALS study.
Each row is one variant; columns:
- VAR_id, CHROM, POS: variant ID, chromosome, genomic position
- ID, REF, ALT: rsID (if any), reference and alternative alleles
- AC, AN, AF: allele count, total alleles, allele frequency
- gene_name: gene where the variant falls
- HighImpact = 1 if high impact (e.g. stop‑gain, frameshift); 0 otherwise
- ModerateImpact = 1 if moderate impact (e.g. missense); 0 otherwise
- Synonymous = 1 if synonymous (silent); 0 otherwise
- CADDphred: CADD phred score; higher = more deleterious; missing = '.'
- PolyPhen: 'D'=probably damaging, 'P'=possibly damaging, 'B'=benign; missing = '.'
- SIFT: 'D'=deleterious, 'T'=tolerated; missing = '.'
- ALS_1 – ALS_5: genotype of 5 ALS patients (0=ref/ref, 1=heterozygous, 2=het/alt)
- Control_1 – Control_5: genotype of 5 controls (same encoding)

Important:
- A variant cannot be both Synonymous and HighImpact at the same time.
- Missing values (CADDphred, PolyPhen, SIFT) are stored as '.', not NULL.
- CADDphred > 20 is generally considered deleterious.
- There is NO group/phenotype column; cases are ALS_1 – ALS_5 and controls are Control_1 – Control_5.
- To compute burden, sum the genotype columns directly (e.g. SUM(ALS_1 + ALS_2 + ...)).
"

# extra instructions setup
extra_instructions <- "
RESPONSE RULES:
- Always start with the direct answer (a number, value, or yes/no) and keep the answer to 1–3 sentences.
- Only use the columns and terms in the data_description above. Never invent or guess column names, gene names, or values.
- If a question cannot be answered from these columns, answer: 'This information is not available in the dataset.' and name the missing column.
- If a term like 'most deleterious' or 'important' is ambiguous, briefly say which metric you use (e.g. CADDphred, HighImpact, case/control ratio) before querying.
- Treat missing values (CADDphred, PolyPhen, SIFT) as '.' and filter with, for example, `WHERE PolyPhen != '.'`.
- Genotype values 0, 1, 2 indicate zygosity only; never interpret them as disease association.
- If asked whether a variant is both synonymous and high impact, explain that these labels are mutually exclusive.
- Do not rewrite, rephrase, or speculate about the question; answer only what is asked.
- NEVER invent a new question or topic. Only answer exactly what the user asked.
- NEVER mention organisms, databases, or tools not present in the dataset (e.g. C. elegans, Ensembl, WormBase).
- If a question uses vague terms like 'important', 'interesting', 'relevant', 'significant', or 'best' without specifying a metric, DO NOT run a query. Instead, ask the user ONE clarifying question such as: 'What do you mean by important? For example, do you mean highest CADDphred score, HighImpact = 1, highest allele frequency, or highest case burden?'
EXAMPLES:
- Question: How many high‑impact variants does the ALS_1 patient carry?
  Interpretation: count variants where HighImpact = 1 AND ALS_1 > 0 (at least one alt allele).
- Question: How many ALS_1 genotypes 2 variants?
  Interpretation: count variants where ALS_1 = 2.
- Question: How many pathogenic variants in SOD1?
  Answer: This information is not available in the dataset. The column for pathogenicity annotation isn't in this dataset.
- Question: Which variants are most important?
  Correct response: 'Important' is ambiguous. Do you mean variants with the highest CADDphred score, HighImpact = 1, highest allele frequency, or highest case burden? Please clarify.
  
For questions like 'how many variants does patient X carry?', interpret 'carries' as variants where the patient's genotype column (e.g. ALS_1) is 1 or 2.
"

# set up QueryChat
qc <- QueryChat$new(
  data_source = gdb,
  table_name = "varInfo_synthetic",
  client = ollama_client,
  data_description = data_description,
  extra_instructions = extra_instructions,
  categorical_threshold = 50,
  greeting = "Welcome! Ask me anything about the ALS variant data. I can help you query variants, genes, genotypes, and more."
)

# test in console first
qc$console()