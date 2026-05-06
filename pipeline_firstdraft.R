library(ellmer)
library(querychat)
library(rollama)

# create the ollama client
ollama_client <- chat_ollama(model = "llama3.1:8b")

# connect to the database
gdb <- gdb(rvat_example("rvatData.gdb"))

# set up QueryChat
qc <- QueryChat$new(
  data_source = gdb,
  table_name = "varInfo_synthetic",
  client = ollama_client,
  data_description = "SIFT: D=deleterious, T=tolerated. PolyPhen: D=damaging, P=possibly damaging, B=benign. Genotype values: 0=homozygous reference, 1=heterozygous, 2=homozygous alternative.",
  greeting = "Ask me anything about the ALS variant data!"
)

# test in console first
qc$console()