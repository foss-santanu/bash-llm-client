#!/bin/bash

# llm_client.sh
# A generic bash script client for LLM inference providers using curl.
# Supports configurable API details, different LLM modes,
# prompt input from file/stdin, and response output to file/stdout.

# --- Global Variables and Defaults ---
CONFIG_FILE="$HOME/.config/llm_client.conf"
LLM_MODE="" # Will be set from config or cmd line
PROMPT_SOURCE="stdin" # Default: read from stdin
PROMPT_FILE=""
OUTPUT_FILE=""
EXTRACT_JSON_RESPONSE=false # Default: print raw JSON
LOG_FILE="$HOME/logs/llm_client.log" # Will be set from config
MAX_OUTPUT_TOKENS=""

CURL_DEBUG=false # Set to 'true' for verbose curl debugging, 'false' to hide.

# --- Logging Function ---
log_message() {
    local type="$1"
    local message="$2"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S") 
    if [[ -n "$LOG_FILE" ]]; then
        echo "[${timestamp}] [${type}] ${message}" >> "$LOG_FILE"
    else
        # Fallback to stderr if log file not configured/accessible
        echo "[${timestamp}] [${type}] ${message}" >&2
    fi
}

log_info() {
    log_message "INFO" "$1"
}

log_warn() {
    log_message "WARN" "$1"
}

log_error() {
    log_message "ERROR" "$1"
}

# --- Help Message ---
show_help() {
    local script_name=$(basename "$0")
    
    echo "Usage: $script_name [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -p, --prompt <text>      Provide prompt directly as a string."
    echo "  -f, --file <file>        Read prompt from specified file."
    echo "                           If neither -p nor -f is given, reads from stdin."
    echo "  -m, --mode <mode>        Specify LLM provider mode (e.g., 'openai', 'gemini')."
    echo "  -k, --max-tokens <number>  Overrides DEFAULT_MAX_TOKEN in config"
    echo "                           Overrides DEFAULT_LLM_MODE in config."
    echo "  -o, --output <file>      Save response to specified file instead of stdout."
    echo "  -e, --extract            Extract and print only the text response from JSON."
    echo "                           Requires 'jq' to be installed."
    echo "  -c, --config <file>      Specify an alternative configuration file."
    echo "  -h, --help               Display this help message."
    echo ""
    echo "Configuration (in $CONFIG_FILE or specified with -c):"
    echo "  DEFAULT_LLM_MODE   : Default LLM mode (e.g., openai, gemini)"
    echo "  LOG_FILE           : Path to the log file"
    echo "  <MODE>_API_KEY     : API Key for the specific mode"
    echo "  <MODE>_API_URL     : API Endpoint URL for the specific mode"
    echo "  <MODE>_MODEL       : Model name for the specific mode"
    echo "  <MODE>_JSON_PATH   : jq path to extract response text (e.g., '.choices[0].message.content')"
    echo ""
    echo "Examples:"
    echo "  $script_name -p \"Tell me a joke.\""
    echo "  $script_name -f my_prompt.txt -o response.json"
    echo "  $script_name -m gemini -p \"What is the capital of India?\" -e"
    echo "  cat my_long_prompt.txt | $script_name -m openai -e"
}

# --- Parse Command Line Arguments ---
parse_args() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -p|--prompt)
                PROMPT_SOURCE="string"
                PROMPT_CONTENT="$2"
                shift
                ;;
            -f|--file)
                PROMPT_SOURCE="file"
                PROMPT_FILE="$2"
                shift
                ;;
            -m|--mode)
                LLM_MODE="$2"
                shift
                ;;
            -k|--max-tokens)
            # 1. Check if the argument is missing or if the next argument is another option
                if [[ -z "$2" || "$2" =~ ^- ]]; then
                    log_error "Error: The '$1' option requires a numeric argument." # Good error message
                    show_help
                    exit 1
                fi
            # 2. Validate that the argument is a positive integer
                if ! [[ "$2" =~ ^[0-9]+$ ]]; then # Checks for one or more digits, correctly handling "0" too
                    log_error "Error: Max tokens value ('$2') must be a positive integer." # Good error message
                    show_help
                    exit 1
                fi
                MAX_OUTPUT_TOKENS="$2"
                shift # Consume the argument ($2)
                ;;
            -o|--output)
                OUTPUT_FILE="$2"
                shift
                ;;
            -e|--extract)
                EXTRACT_JSON_RESPONSE=true
                ;;
            -c|--config)
                CONFIG_FILE="$2"
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
        shift
    done
}

# --- Load Configuration ---
load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        echo "Error: Configuration file not found at '$CONFIG_FILE'." >&2
        echo "Please create it or specify with -c." >&2
        exit 1
    fi

    log_info "Loading configuration from $CONFIG_FILE"
    # Read variables from config file
    # Ensure no spaces around '=' for assignment
    # Use 'declare -A' if you want associative arrays, but simple variables are fine here.
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        # Ignore comments and empty lines
        [[ "$key" =~ ^#.* ]] && continue
        [[ -z "$key" ]] && continue

        # Trim whitespace from key and value
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | sed 's/\s*#.*//' | xargs)

        # Skip if value is empty or commented out
        [[ -z "$value" ]] && continue

        # Export variables to make them accessible to curl command
        export "${key}=${value}"
    done < "$CONFIG_FILE"

    # Set LOG_FILE from config if not already set (e.g., by default value)
##    if [[ -z "$LOG_FILE" && -n "$_LOG_FILE" ]]; then
##        LOG_FILE="$_LOG_FILE"
##    fi

    # Set default mode if not specified via command line
    if [[ -z "$LLM_MODE" && -n "$DEFAULT_LLM_MODE" ]]; then
        LLM_MODE="$DEFAULT_LLM_MODE"
    fi

    if [[ -z "$MAX_OUTPUT_TOKENS" && -n "$DEFAULT_MAX_TOKEN" ]]; then
        MAX_OUTPUT_TOKENS="$DEFAULT_MAX_TOKEN"
    fi

    if [[ -z "$LLM_MODE" ]]; then
        log_error "LLM mode not specified and DEFAULT_LLM_MODE not set in config."
        echo "Error: LLM mode not specified. Use -m or set DEFAULT_LLM_MODE in config." >&2
        exit 1
    fi

    # Dynamically set API details based on LLM_MODE
    API_KEY_VAR="${LLM_MODE^^}_API_KEY"
    API_URL_VAR="${LLM_MODE^^}_API_URL"
    MODEL_VAR="${LLM_MODE^^}_MODEL"
    JSON_PATH_VAR="${LLM_MODE^^}_JSON_PATH"

    API_KEY="${!API_KEY_VAR}"
    API_URL="${!API_URL_VAR}"
    MODEL="${!MODEL_VAR}"
    JSON_PATH="${!JSON_PATH_VAR}"

    if [[ -z "$API_KEY" || "$API_KEY" == "YOUR_"* ]]; then
        log_error "API_KEY for mode '$LLM_MODE' not found or not set in config. (Variable: $API_KEY_VAR)"
        echo "Error: API key for mode '$LLM_MODE' is missing or not configured correctly." >&2
        echo "Please set ${API_KEY_VAR} in $CONFIG_FILE." >&2
        exit 1
    fi
    if [[ -z "$API_URL" ]]; then
        log_error "API_URL for mode '$LLM_MODE' not found in config. (Variable: $API_URL_VAR)"
        echo "Error: API URL for mode '$LLM_MODE' is missing in config." >&2
        echo "Please set ${API_URL_VAR} in $CONFIG_FILE." >&2
        exit 1
    fi
    if [[ -z "$MODEL" ]]; then
        log_warn "MODEL for mode '$LLM_MODE' not found in config. (Variable: $MODEL_VAR)"
        log_warn "Using default model for API if applicable, or might fail."
        echo "Warning: Model for mode '$LLM_MODE' is not explicitly set in config." >&2
    fi
    if [[ "$EXTRACT_JSON_RESPONSE" == true && -z "$JSON_PATH" ]]; then
        log_warn "JSON_PATH for mode '$LLM_MODE' not found in config. (Variable: $JSON_PATH_VAR)"
        log_warn "Cannot extract specific text; will output raw JSON."
        echo "Warning: JSON path for extraction not found. Outputting raw JSON." >&2
        EXTRACT_JSON_RESPONSE=false # Fallback
    fi

    log_info "Mode: $LLM_MODE"
    log_info "API URL: $API_URL"
    log_info "Model: $MODEL"
    log_info "JSON Path for extraction: ${JSON_PATH:-N/A (raw output)}"
}

# --- Read Prompt Content ---
read_prompt() {
    if [[ "$PROMPT_SOURCE" == "string" ]]; then
        # Prompt provided directly as argument
        log_info "Reading prompt from command line argument."
        echo "$PROMPT_CONTENT"
    elif [[ "$PROMPT_SOURCE" == "file" ]]; then
        # Prompt from file
        if [[ ! -f "$PROMPT_FILE" ]]; then
            log_error "Prompt file not found: $PROMPT_FILE"
            echo "Error: Prompt file '$PROMPT_FILE' not found." >&2
            exit 1
        fi
        log_info "Reading prompt from file: $PROMPT_FILE"
        cat "$PROMPT_FILE"
    else # Default to stdin
        log_info "Reading prompt from stdin. Press Ctrl+D to finish input."
        cat /dev/stdin
    fi
}

# --- Construct JSON Payload ---
construct_payload() {
    local prompt="$1"
    local json_payload=""

    case "$LLM_MODE" in
        openai)
            json_payload=$(jq -n \
                --arg model "$MODEL" \
                --arg user_prompt "$prompt" \
                --arg max_tokens "$MAX_OUTPUT_TOKENS" \
                '{
                    "model": $model,
                    "messages": [
                        {"role": "user", "content": $user_prompt}
                    ],
                    "max_tokens": ($max_tokens | tonumber),
                    "temperature": 0.7
                }')
            ;;
        gemini)
            json_payload=$(jq -n \
                --arg user_prompt "$prompt" \
                --arg max_tokens "$MAX_OUTPUT_TOKENS" \
                '{
                    "contents": [
                        {"parts": [{"text": $user_prompt}]}
                    ],
                    "generationConfig": {
                        "temperature": 0.7,
                        "maxOutputTokens": ($max_tokens | tonumber)
                    }
                }')
            ;;
        # Add more cases for other LLM providers here
        # Example for Cohere:
        # cohere)
        #     json_payload=$(jq -n \
        #         --arg model "$MODEL" \
        #         --arg user_prompt "$prompt" \
        #         '{
        #             "prompt": $user_prompt,
        #             "model": $model,
        #             "max_tokens": 1024,
        #             "temperature": 0.7
        #         }')
        #     ;;
        *)
            log_error "Unsupported LLM mode: $LLM_MODE"
            echo "Error: Unsupported LLM mode '$LLM_MODE'." >&2
            exit 1
            ;;
    esac
    echo "$json_payload"
}

# --- Make API Call with Curl ---
make_api_call() {
    local json_data="$1"
    local response=""
    local http_status=""
    local -a curl_args=() # <--- Key change: Declare an array for curl arguments

    log_info "Sending request to $API_URL"
    log_info "Request Payload: $json_data"

    local temp_response_file=$(mktemp)
    local temp_headers_file=$(mktemp) 

    local api_url_to_use="$API_URL"

    # Common curl arguments (add directly to array)
    curl_args+=(
        -s # Silent mode
        -o "$temp_response_file" # Output to temp file
        -w "%{http_code}" # Write HTTP status code
        -X POST # Explicitly specify POST method
        -H "Content-Type: application/json" # Content type header
    )

    # Add mode-specific authentication header (add directly to array)
    # NO NEED for \" escaping here because Bash arrays handle it.
    case "$LLM_MODE" in
        openai)
            curl_args+=(-H "Authorization: Bearer $API_KEY") # No backslashes needed!
            ;;
        gemini)
            curl_args+=(-H "X-Goog-Api-Key: $API_KEY") # No backslashes needed!
            ;;
        *)
            log_error "Unsupported LLM mode: $LLM_MODE for API authentication setup."
            echo "Error: Unsupported LLM mode '$LLM_MODE' for API authentication." >&2
            return 1
            ;;
    esac

    # Add the JSON data payload
    curl_args+=(-d "$json_data") # Use "$json_data" to pass the JSON string as one argument

    # Add the target URL
    curl_args+=("$api_url_to_use")

    # --- DEBUGGING STEP (updated for array execution) ---
    if [[ "$CURL_DEBUG" == true ]]; then
        log_message "DEBUG" "Executing curl command (via array):"
        # This will print the command in a way that shows individual arguments
        log_message "DEBUG" "curl $(printf " '%s'" "${curl_args[@]}")"
        echo "DEBUG: To manually verify, copy and adjust quotes around sensitive parts like API_KEY and full JSON data:" >&2
        echo "curl -s -o \"$temp_response_file\" -w \"%{http_code}\" -X POST -H \"Content-Type: application/json\" -H \"$(echo "$API_KEY" | sed 's/"/\\"/g')\" -d '$json_data' \"$api_url_to_use\"" >&2
    fi
    # --- END DEBUGGING STEP ---

    # Execute curl command directly from array
    # This avoids all eval quoting issues.
    # All output goes to stdout (and then captured by http_status variable)
    http_status=$(curl "${curl_args[@]}" 2>&1)

    curl_exit_code=$?

    # Separate HTTP status code from the actual response/error body
    local raw_curl_output="$http_status"
    http_status=$(echo "$raw_curl_output" | tail -n 1) # Extract the last line as HTTP code
    response_body_from_output=$(echo "$raw_curl_output" | head -n -1) # Rest is verbose output or initial error

    # If -o was used, the actual response body goes to $temp_response_file
    # We prioritize content from the -o file for the actual LLM response
    if [[ -f "$temp_response_file" && -s "$temp_response_file" ]]; then # -s checks if file is not empty
        response=$(cat "$temp_response_file")
    else
        response="$response_body_from_output" # Fallback to captured output if temp file empty/non-existent
    fi

    rm "$temp_response_file" "$temp_headers_file" # Clean up temp files

    if [[ "$CURL_DEBUG" == true ]]; then
        log_message "DEBUG" "Curl Exit Code: $curl_exit_code"
        log_message "DEBUG" "HTTP Status: $http_status"
        log_message "DEBUG" "Raw Curl Output (including -v data if enabled):"
        log_message "DEBUG" "$raw_curl_output"
        log_message "DEBUG" "Final LLM Response Body:"
        log_message "DEBUG" "$response"
    fi

    if [[ "$curl_exit_code" -ne 0 ]]; then
        log_error "Curl command failed with exit code $curl_exit_code. HTTP Status: ${http_status:-N/A}. Curl Output: $raw_curl_output"
        echo "Error: Failed to connect to LLM provider or API request failed." >&2
        echo "Curl error details (check log for full verbose output):" >&2
        if [[ "$CURL_DEBUG" != true ]]; then
            echo "$raw_curl_output" | head -n 5 >&2
        fi
        return 1
    fi

    # Check HTTP status for API errors (4xx/5xx)
    if [[ "$http_status" =~ ^[0-9]+$ ]] && [[ "$http_status" -ge 400 ]]; then
        log_error "API returned an error HTTP Status: $http_status. Response: $response"
        echo "Error: LLM API returned an error (HTTP Status: $http_status)." >&2
        echo "Response: $response" >&2
        return 1
    fi
    # This check is less critical now due to `curl_exit_code` check, but good for explicit clarity.
    if [[ -z "$http_status" ]]; then
        log_error "Curl command did not return an HTTP status code. Likely a connection error. Full output: $raw_curl_output"
        echo "Error: No HTTP status code received. Likely connection issue." >&2
        return 1
    fi

    echo "$response" # Return the raw JSON response
    return 0
}

# --- Main Script Logic ---
main() {
    parse_args "$@"

    # Initialize log file path before loading config if default is used
    # Or ensure it's loaded from config early for all logging.
    # LOG_FILE is set by default or by config.
    # If config file doesn't exist, log_error will output to stderr.
    log_info "Script started."

    load_config

    # Check for jq if extraction is requested
    if [[ "$EXTRACT_JSON_RESPONSE" == true ]]; then
        if ! command -v jq &> /dev/null; then
            log_error "jq is not installed. Cannot extract JSON response. Please install it ('pkg install jq' in Termux)."
            echo "Error: 'jq' not found. Cannot extract JSON response. Install it or remove -e." >&2
            EXTRACT_JSON_RESPONSE=false # Fallback to raw output
        fi
    fi

    # Read the prompt
    PROMPT=$(read_prompt)
    if [[ -z "$PROMPT" ]]; then
        log_error "No prompt provided."
        echo "Error: No prompt provided. Use -p, -f, or pipe input." >&2
        exit 1
    fi

    # Construct the JSON payload
    JSON_PAYLOAD=$(construct_payload "$PROMPT")
    if [[ $? -ne 0 ]]; then
        # Error already logged by construct_payload
        exit 1
    fi

    # Make the API call
    API_RESPONSE=$(make_api_call "$JSON_PAYLOAD")
    if [[ $? -ne 0 ]]; then
        # Error already logged by make_api_call
        exit 1
    fi

    log_info "API Call Successful. Processing response."

    local final_output="$API_RESPONSE"

    # Extract response if requested
    if [[ "$EXTRACT_JSON_RESPONSE" == true && -n "$JSON_PATH" ]]; then
        extracted_text=$(echo "$API_RESPONSE" | jq -r "$JSON_PATH" 2>/dev/null)
        if [[ $? -ne 0 ]]; then
            log_warn "Failed to extract text using jq path: '$JSON_PATH'. Outputting raw JSON."
            echo "Warning: Failed to extract text from response. Outputting raw JSON." >&2
        else
            final_output="$extracted_text"
        fi
    fi

    # Output the response
    if [[ -n "$OUTPUT_FILE" ]]; then
        echo "$final_output" > "$OUTPUT_FILE"
        log_info "Response saved to: $OUTPUT_FILE"
    else
        echo "$final_output"
    fi

    log_info "Script finished successfully."
}

# --- Execute Main Function ---
main "$@"
