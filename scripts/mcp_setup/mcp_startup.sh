#!/bin/bash

# activate conda and start Open WebUI in background
source ~/miniconda3/bin/activate webui
open-webui serve &

# start mcpo in background
mcpo --port 8000 -- python3 /Users/sjoerd/Rstudio/dsfb2_project_sandbox/server.py &

echo "All services started"
echo "Open http://localhost:8080 in your browser"