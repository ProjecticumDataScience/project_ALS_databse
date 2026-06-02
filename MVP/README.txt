─────────────────────────────────────────────────────
Project ALS MCP — minimal viable product
─────────────────────────────────────────────────────

First time only setup
  1.activate the following ollama model in the terminal:
    ollama pull model llama3.1:8b
    And activate it: ollama run llama3.1:8b
  
  2.Create the conda environment:
    conda env create -f \~/project_ALS_databse/MVP/environment.yml
  
  3.Go to line 7 in start_services.sh and change the PROJECT_DIR to
    the location on your computer
─────────────────────────────────────────────────────

Startup
  1.Run this script: bash start_services.sh
  2.Run this script: app.R

  A new tab should open in your browser with the shiney website. Somewhere on 
  the left it should say "Verbindingsstatus: MCP verbonden". If this is not the case try
  running the script start_services.sh again.
