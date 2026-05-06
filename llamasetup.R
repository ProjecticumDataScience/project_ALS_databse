library(rollama)

# point rollama at the local ollama server
options(rollama_server = "http://localhost:11434")

# check it's working
ping_ollama()

# confirm the model is available
pull_model("llama3.1:8b")  # won't re-download, just verifies