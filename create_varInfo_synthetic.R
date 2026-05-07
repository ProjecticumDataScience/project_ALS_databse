## Load packages
library(rvat)
library(rvatData)
library(DBI)
library(ellmer)
library(querychat)

## Load example gdb
gdb <- gdb(rvat_example("rvatData.gdb"))

## Write synthetic genotype data
vi <- dbGetQuery(gdb, "SELECT * FROM varInfo")
set.seed(123)
n_rows <- nrow(vi)
geno_als <- replicate(5, sample(0:2, n_rows, replace = TRUE))
colnames(geno_als) <- paste0("ALS_", 1:5)
geno_control <- replicate(5, sample(0:2, n_rows, replace = TRUE))
colnames(geno_control) <- paste0("Control_", 1:5)
vi_updated <- cbind(vi, geno_als, geno_control)
dbWriteTable(gdb, "varInfo_synthetic", vi_updated, overwrite = TRUE)

## Data description
data_description <- "
This table contains genomic variant data from the Project MinE ALS study.
Each row is a single genetic variant.

COLUMNS:
- VAR_id: unique variant identifier (integer)
- CHROM: chromosome (e.g. chr1)
- POS: genomic position (integer)
- ID: variant rsID if known, otherwise NA
- REF: reference allele
- ALT: alternative allele
- AC: allele count
- AN: total alleles
- AF: allele frequency (decimal)
- gene_name: gene the variant is located in (text)
- HighImpact: 1 if high impact (stop gain, frameshift), 0 otherwise
- ModerateImpact: 1 if moderate impact (missense), 0 otherwise
- Synonymous: 1 if synonymous/silent, 0 otherwise
- CADDphred: deleteriousness score (higher = more deleterious). Missing = '.' (a dot string, not NULL)
- PolyPhen: D=probably damaging, P=possibly damaging, B=benign. Missing = '.' (a dot string, not NULL)
- SIFT: D=deleterious, T=tolerated. Missing = '.' (a dot string, not NULL)
- ALS_1 to ALS_5: genotype of 5 ALS patients
- Control_1 to Control_5: genotype of 5 control individuals
- Genotype encoding: 0=homozygous reference, 1=heterozygous, 2=homozygous alternative

CRITICAL FACTS ABOUT THE DATA:
- Missing values are the string '.' not NULL. To filter out missing: WHERE column != '.'
- CADDphred is stored as text due to missing values. Cast with: CAST(CADDphred AS REAL)
- A variant CANNOT be both Synonymous=1 and HighImpact=1 simultaneously
- Genotype values (0, 1, 2) indicate zygosity ONLY, not disease association
- ALS_1 to ALS_5 are synthetic/simulated genotypes for testing purposes only
"

## Extra instructions
extra_instructions <- "
RESPONSE RULES — FOLLOW THESE STRICTLY:
1. ALWAYS start your response with the direct answer (e.g. a count, a value, a yes/no).
2. NEVER exceed 3 sentences in your response.
3. NEVER list individual rows or variants. Summarize only.
4. NEVER rewrite, rephrase, or speculate about what the user might be asking. Answer what was asked.
5. NEVER write Python, R, or any other code in your response.
6. NEVER interpret genotype values (0, 1, 2) as disease association. They indicate zygosity only.
7. If a question cannot be answered with the available data, respond ONLY with: 'This information is not available in the dataset.' and specify which column is missing.
8. If a question is ambiguous, ask ONE clarifying question before querying.
9. NEVER hallucinate column names, table names, gene names, or values not present in the schema.
10. NEVER guess. If you are uncertain, say 'I don't know.'
"

## Ollama client
ollama_client <- chat_ollama(
  model = "llama3.1:8b",
  params = params(
    temperature = 0.1,
    num_predict = 200
  )
)

## Build QueryChat
qc <- QueryChat$new(
  data_source = gdb,
  table_name = "varInfo_synthetic",
  client = ollama_client,
  data_description = data_description,
  extra_instructions = extra_instructions,
  categorical_threshold = 50,
  greeting = "Welcome! Ask me anything about the ALS variant data. I can query variants, genes, genotypes, and more."
)

## Launch console
qc$console()