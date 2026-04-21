library(rollama)

# This checks that Ollama is running and the model is available
pull_model("llama3")       # downloads the model if not already present

# A simple test to verify it works
query("What is ALS?", model = "llama3")