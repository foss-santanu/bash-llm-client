# Bash-llm-client

```
Usage: llm_client.sh [OPTIONS]

Options:
  -p, --prompt <text>      Provide prompt directly as a string.
  -f, --file <file>        Read prompt from specified file.
                           If neither -p nor -f is given, reads from stdin.
  -m, --mode <mode>        Specify LLM provider mode (e.g., 'openai', 'gemini').
  -k, --max-tokens <number>  Overrides DEFAULT_MAX_TOKEN in config
                           Overrides DEFAULT_LLM_MODE in config.
  -o, --output <file>      Save response to specified file instead of stdout.
  -e, --extract            Extract and print only the text response from JSON.
                           Requires 'jq' to be installed.
  -c, --config <file>      Specify an alternative configuration file.
  -h, --help               Display this help message.

Configuration (in /data/data/com.termux/files/home/.config/llm_client.conf or specified with -c):
  DEFAULT_LLM_MODE   : Default LLM mode (e.g., openai, gemini)
  LOG_FILE           : Path to the log file
  <MODE>_API_KEY     : API Key for the specific mode
  <MODE>_API_URL     : API Endpoint URL for the specific mode
  <MODE>_MODEL       : Model name for the specific mode
  <MODE>_JSON_PATH   : jq path to extract response text (e.g., '.choices[0].message.content')

Examples:
  llm_client.sh -p "Tell me a joke."
  llm_client.sh -f my_prompt.txt -o response.json
  llm_client.sh -m gemini -p "What is the capital of India?" -e
  cat my_long_prompt.txt | llm_client.sh -m openai -e

```
