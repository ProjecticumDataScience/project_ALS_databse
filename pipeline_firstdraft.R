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
  greeting = "Ask me anything about the ALS variant data!"
)

# test in console first
qc$console()