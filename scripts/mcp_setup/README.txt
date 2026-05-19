****************************
How to setup the MCP server
****************************

This version of the mcp server runs locally and requires 4 programs/scripts.
For some programms a conda environment is required to install them. 


  -MCP server
    This is a python scrip that contains the mcp. In our case it is called
    server.py. In this script you need to provide a directory to your database.
    
    The script mcp can be activate as a normal bash script: bash server.py.
    It will run in the background
    
  -Ollama
     Ollama provides free llm models. Install Ollama here: https://ollama.com/.
     Keep ollama running in the background when starting up the server.
     
  -Open WebUI
    This program hosts the llm and provides an environment to ask questions.
    This is also where you give the llm acces to the mcp server and provide a
    data description.
    
    Open WebUI needs to be installed in a conda environment because it uses
    an older version of python. First create this environment and then install
    it with the following command: pip install open-webui.
    
    Start the server in bash: source ~/miniconda3/bin/activate webui
                      open-webui serve &
  
  -mcpo
    This functions as a bridge between the mcp server and Open WebUI.
    Install it in the same conda environment as Open WebUI: pip install mcpo.
    Run it with this command:
      mcpo --port 8000 -- python3 /Path/to/server/server.py &
 
 
**********************
How to run the server 
**********************

Once everything is installed you need to run the applications in the background.
We have written a two bash scripts for starting up and shutting down the server:
mcp_startup.sh & mcp_shutdown.sh.

When everything is running you can acces Open WebUI by pasting
this link in a browser: http://localhost:8080. You might need to choose a
username and a password before you can acces the llm. When this is done you
should see an environment similar to commercial llm's like claude and chatgpt.
In the chat bar there is a small diamond shaped icon. Click it and choose your
tools. Finally go to the settings located at the top right of the screen and
add a description of your data. You will have to tweak this in order for the
llm to answer your questions correctly.
