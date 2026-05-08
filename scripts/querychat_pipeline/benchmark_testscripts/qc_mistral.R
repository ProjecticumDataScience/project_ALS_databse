library(ellmer)
library(querychat)
library(rollama)

# create the ollama client
ollama_client <- chat_ollama(
  model = "mistral",
  params = params(
    temperature = 0.1,
    num_predict = 200
  )
)

# connect to the database
gdb <- gdb(rvat_example("rvatData.gdb"))

# data description setup
data_description <- "
This table contains genomic variant data from the Project MinE ALS study.
Each row represents a single genetic variant with the following columns:
- VAR_id: unique variant identifier
- CHROM: chromosome (e.g. chr1)
- POS: genomic position
- ID: variant rsID if known
- REF/ALT: reference and alternative alleles
- AC: allele count, AN: total alleles, AF: allele frequency
- gene_name: gene the variant is located in
- HighImpact: 1 if variant is high impact (e.g. stop gain, frameshift), 0 otherwise
- ModerateImpact: 1 if variant is moderate impact (e.g. missense), 0 otherwise
- Synonymous: 1 if variant is synonymous (silent), 0 otherwise
- CADDphred: CADD phred score measuring deleteriousness (higher = more deleterious). Missing values are stored as '.'
- PolyPhen: PolyPhen-2 prediction. D=probably damaging, P=possibly damaging, B=benign. Missing = '.'
- SIFT: SIFT prediction. D=deleterious, T=tolerated. Missing = '.'
- ALS_1 to ALS_5: genotype of 5 ALS patients (0=homozygous reference, 1=heterozygous, 2=homozygous alternative)
- Control_1 to Control_5: genotype of 5 control individuals (same encoding)
Important notes:
- A variant cannot be both Synonymous and HighImpact simultaneously
- Missing annotation values are stored as '.' not NULL
- CADDphred scores above 20 are generally considered deleterious
"

# extra instructions setup
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
11. Missing values are stored as '.' not NULL. Use WHERE column != '.' to filter missing values.
12. A variant cannot be both Synonymous and HighImpact simultaneously. If asked, explain this to the user.
13. When terms like 'most deleterious' or 'important' are used, briefly explain your definition before querying.
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