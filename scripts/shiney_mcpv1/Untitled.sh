#!/bin/bash

pkill -f "open-webui"
pkill -f "mcpo"
pkill -f "server.py"

echo "All services stopped"