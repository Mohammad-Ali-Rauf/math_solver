#!/bin/bash

set -e

# Configuration
SCRIPT_NAME="math_solver.sh"
API_URL="https://router.huggingface.co/v1/chat/completions"
MODEL="Qwen/Qwen3-VL-235B-A22B-Thinking:novita"
TOKEN_FILE="./.hf_token"
DB_FILE="${MATH_SOLVER_DB:-$HOME/.local/share/math_solver/problems.db}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/math_solver"
SCRIPT_VERSION="3.0.0"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Log functions
log() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

# Display usage
usage() {
    echo -e "${BOLD}Usage:${NC} $SCRIPT_NAME <command> [options]"
    echo ""
    echo -e "${BOLD}Commands:${NC}"
    echo "  solve <image>          Solve a math problem from image"
    echo "  list [topic]           List solved problems (optional topic filter)"
    echo "  show <problem_id>      Show solution for specific problem"
    echo "  search <query>         Search problems by content"
    echo "  topics                 List all topics"
    echo "  stats                  Show database statistics"
    echo "  export <format>        Export solutions (json/sql)"
    echo ""
    echo -e "${BOLD}Solve Options:${NC}"
    echo "  --topic <name>         Categorize problem under topic"
    echo "  --json                 Output raw JSON"
    echo "  --no-cache             Skip cache"
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo "  $SCRIPT_NAME solve problem.png --topic algebra"
    echo "  $SCRIPT_NAME list calculus"
    echo "  $SCRIPT_NAME show prob_abc123"
    echo "  $SCRIPT_NAME search \"binomial expansion\""
    echo "  $SCRIPT_NAME stats"
    echo "  $SCRIPT_NAME export json"
}

# Database functions
init_db() {
    mkdir -p "$(dirname "$DB_FILE")"
    mkdir -p "$CACHE_DIR"
    
    sqlite3 "$DB_FILE" << 'EOF'
CREATE TABLE IF NOT EXISTS problems (
    id TEXT PRIMARY KEY,
    image_hash TEXT UNIQUE NOT NULL,
    topic TEXT,
    problem_description TEXT NOT NULL,
    final_answer TEXT NOT NULL,
    key_concepts TEXT NOT NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    image_path TEXT
);

CREATE TABLE IF NOT EXISTS solution_steps (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    problem_id TEXT NOT NULL,
    step_number INTEGER NOT NULL,
    description TEXT NOT NULL,
    calculation TEXT NOT NULL,
    result TEXT NOT NULL,
    FOREIGN KEY (problem_id) REFERENCES problems (id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_problems_topic ON problems(topic);
CREATE INDEX IF NOT EXISTS idx_problems_created ON problems(created_at);
CREATE INDEX IF NOT EXISTS idx_steps_problem ON solution_steps(problem_id);
EOF
}

generate_problem_id() {
    echo "prob_$(date +%s)_$(openssl rand -hex 4)"
}

get_image_hash() {
    local image_path="$1"
    sha256sum "$image_path" | cut -d' ' -f1
}

problem_exists() {
    local image_hash="$1"
    sqlite3 "$DB_FILE" "SELECT id FROM problems WHERE image_hash = '$image_hash';"
}

save_solution() {
    local problem_id="$1"
    local image_hash="$2"
    local topic="$3"
    local image_path="$4"
    local json_data="$5"
    
    local problem_desc=$(echo "$json_data" | jq -r '.problem_description' | sed "s/'/''/g")
    local final_answer=$(echo "$json_data" | jq -r '.final_answer' | sed "s/'/''/g")
    local key_concepts=$(echo "$json_data" | jq -r '.key_concepts | join(", ")' | sed "s/'/''/g")
    
    # Insert problem
    sqlite3 "$DB_FILE" << EOF
INSERT INTO problems (id, image_hash, topic, problem_description, final_answer, key_concepts, image_path)
VALUES ('$problem_id', '$image_hash', '$topic', '$problem_desc', '$final_answer', '$key_concepts', '$image_path');
EOF
    
    # Insert solution steps
    local steps_count=$(echo "$json_data" | jq '.solution_steps | length')
    for ((i=0; i<steps_count; i++)); do
        local step_num=$((i+1))
        local desc=$(echo "$json_data" | jq -r ".solution_steps[$i].description" | sed "s/'/''/g")
        local calc=$(echo "$json_data" | jq -r ".solution_steps[$i].calculation" | sed "s/'/''/g")
        local result=$(echo "$json_data" | jq -r ".solution_steps[$i].result" | sed "s/'/''/g")
        
        sqlite3 "$DB_FILE" << EOF
INSERT INTO solution_steps (problem_id, step_number, description, calculation, result)
VALUES ('$problem_id', $step_num, '$desc', '$calc', '$result');
EOF
    done
    
    log "Solution saved to database: $problem_id"
}

get_solution() {
    local problem_id="$1"
    
    # Get the main problem data
    local problem_data=$(sqlite3 -json "$DB_FILE" << EOF
SELECT 
    problem_description as "problem_description",
    final_answer as "final_answer", 
    key_concepts as "key_concepts"
FROM problems 
WHERE id = '$problem_id';
EOF
    )
    
    # Get solution steps as separate JSON
    local steps_data=$(sqlite3 -json "$DB_FILE" << EOF
SELECT 
    step_number as "step_number",
    description as "description", 
    calculation as "calculation",
    result as "result"
FROM solution_steps 
WHERE problem_id = '$problem_id'
ORDER BY step_number;
EOF
    )
    
    # Combine the data - return as single object, not array
    if [[ -n "$problem_data" && "$problem_data" != "[]" ]]; then
        echo "$problem_data" | jq --argjson steps "$steps_data" \
            '.[0] + {solution_steps: $steps}'
    else
        echo "{}"
    fi
}

list_problems() {
    local topic_filter="$1"
    
    local where_clause=""
    if [[ -n "$topic_filter" ]]; then
        where_clause="WHERE topic = '$topic_filter'"
    fi
    
    sqlite3 -header -column "$DB_FILE" << EOF
SELECT 
    id as "Problem ID",
    topic as "Topic", 
    substr(problem_description, 1, 50) || '...' as "Description",
    final_answer as "Answer",
    created_at as "Solved On"
FROM problems 
$where_clause
ORDER BY created_at DESC
LIMIT 50;
EOF
}

search_problems() {
    local query="$1"
    
    sqlite3 -header -column "$DB_FILE" << EOF
SELECT 
    id as "Problem ID",
    topic as "Topic",
    substr(problem_description, 1, 50) || '...' as "Description",
    final_answer as "Answer"
FROM problems 
WHERE problem_description LIKE '%$query%' 
   OR final_answer LIKE '%$query%'
   OR key_concepts LIKE '%$query%'
ORDER BY created_at DESC
LIMIT 20;
EOF
}

list_topics() {
    sqlite3 -header -column "$DB_FILE" << EOF
SELECT 
    topic as "Topic",
    COUNT(*) as "Problems",
    MAX(created_at) as "Last Solved"
FROM problems 
WHERE topic IS NOT NULL
GROUP BY topic
ORDER BY COUNT(*) DESC;
EOF
}

show_stats() {
    echo -e "${BOLD}Database Statistics:${NC}"
    echo ""
    
    sqlite3 "$DB_FILE" << EOF
.mode line
SELECT 
    (SELECT COUNT(*) FROM problems) as "Total Problems",
    (SELECT COUNT(DISTINCT topic) FROM problems WHERE topic IS NOT NULL) as "Unique Topics",
    (SELECT COUNT(*) FROM solution_steps) as "Total Solution Steps",
    (SELECT strftime('%Y-%m-%d', MIN(created_at)) FROM problems) as "First Solution",
    (SELECT strftime('%Y-%m-%d', MAX(created_at)) FROM problems) as "Last Solution";
EOF
    
    echo ""
    echo -e "${BOLD}Top Topics:${NC}"
    sqlite3 -header -column "$DB_FILE" "SELECT topic, COUNT(*) as count FROM problems WHERE topic IS NOT NULL GROUP BY topic ORDER BY count DESC LIMIT 5;"
}

export_solutions() {
    local format="$1"
    
    case "$format" in
        json)
            sqlite3 -json "$DB_FILE" "SELECT * FROM problems ORDER BY created_at DESC;" | jq .
            ;;
        sql)
            sqlite3 "$DB_FILE" ".dump"
            ;;
        *)
            log_error "Unknown export format: $format"
            echo "Available formats: json, sql"
            exit 1
            ;;
    esac
}

# Pretty print functions
print_header() {
    echo -e "${PURPLE}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════════════╗"
    echo "║                           MATH SOLUTION                              ║"
    echo "╚══════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_step() {
    local step_num="$1"
    local title="$2"
    echo -e "${CYAN}${BOLD}"
    echo "┌──────────────────────────────────────────────────────────────────────┐"
    echo "│   STEP $step_num: $title"
    echo "└──────────────────────────────────────────────────────────────────────┘"
    echo -e "${NC}"
}

print_final_answer() {
    echo -e "${GREEN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════════════╗"
    echo "║                            FINAL ANSWER                              ║"
    echo "╚══════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

get_token() {
    if [[ ! -f "$TOKEN_FILE" ]]; then
        log_error "Token file not found: $TOKEN_FILE"
        echo "Get token from: https://huggingface.co/settings/tokens"
        echo "Then run: echo 'your_token' > .hf_token"
        exit 1
    fi
    cat "$TOKEN_FILE" | tr -d '[:space:]'
}

call_api() {
    local image_url="$1"
    local hf_token="$2"
    
    local json_payload
    json_payload=$(jq -n \
        --arg model "$MODEL" \
        --arg image_url "$image_url" \
        '{
            "messages": [
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "text",
                            "text": "Analyze this math problem and respond with ONLY valid JSON in this exact structure:\n\n{\n  \"problem_description\": \"Brief description of the problem\",\n  \"solution_steps\": [\n    {\n      \"step_number\": 1,\n      \"description\": \"What is done in this step\",\n      \"calculation\": \"Mathematical work shown\",\n      \"result\": \"Output of this step\"\n    }\n  ],\n  \"final_answer\": \"The complete solution\",\n  \"key_concepts\": [\"concept1\", \"concept2\"]\n}\n\nIMPORTANT: Return ONLY the JSON, no other text, no markdown, no boxed formatting."
                        },
                        {
                            "type": "image_url",
                            "image_url": {
                                "url": $image_url
                            }
                        }
                    ]
                }
            ],
            "model": $model,
            "max_tokens": 2000
        }')
    
    curl -s -X POST "$API_URL" \
        -H "Authorization: Bearer $hf_token" \
        -H "Content-Type: application/json" \
        -d "$json_payload"
}

display_pretty_solution() {
    local json_data="$1"
    
    print_header
    
    # Problem Description
    echo -e "${YELLOW}${BOLD}PROBLEM:${NC}"
    echo -e "  $(echo "$json_data" | jq -r '.problem_description')\n"
    
    # Solution Steps
    echo -e "${CYAN}${BOLD}SOLUTION STEPS:${NC}"
    local steps_count=$(echo "$json_data" | jq '.solution_steps | length')
    
    for ((i=0; i<steps_count; i++)); do
        local step_num=$((i+1))
        print_step "$step_num" "$(echo "$json_data" | jq -r ".solution_steps[$i].description")"
        
        echo -e "${BLUE}Calculation:${NC}"
        echo -e "  $(echo "$json_data" | jq -r ".solution_steps[$i].calculation")"
        
        echo -e "${GREEN}Result:${NC}"
        echo -e "  $(echo "$json_data" | jq -r ".solution_steps[$i].result")\n"
    done
    
    # Final Answer
    print_final_answer
    echo -e "  $(echo "$json_data" | jq -r '.final_answer')\n"
    
    # Key Concepts
    echo -e "${PURPLE}${BOLD}KEY CONCEPTS:${NC}"
    echo "$json_data" | jq -r '.key_concepts[]' | while read -r concept; do
        echo -e "  • $concept"
    done
}

display_json_solution() {
    local json_data="$1"
    echo "$json_data" | jq .
}

# Command handlers
cmd_solve() {
    local image_url="$1"
    local topic=""
    local output_format="pretty"
    local use_cache=true

    # Parse options
    while [[ $# -gt 0 ]]; do
        case $1 in
            --topic)
                topic="$2"
                shift 2
                ;;
            --json)
                output_format="json"
                shift
                ;;
            --no-cache)
                use_cache=false
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    # Validate URL format
    if [[ ! "$image_url" =~ ^https?:// ]]; then
        log_error "Invalid or missing image URL: $image_url"
        exit 1
    fi

    init_db
    local hf_token=$(get_token)
    local image_hash=$(echo -n "$image_url" | sha256sum | awk '{print $1}')

    # Check cache
    local existing_id=$(problem_exists "$image_hash")
    if [[ -n "$existing_id" && "$use_cache" == true ]]; then
        log "Problem already solved: $existing_id"
        local cached_json=$(get_solution "$existing_id")

        if [[ -z "$cached_json" || "$cached_json" == "{}" ]]; then
            log_error "Cached solution data is empty or invalid"
            exit 1
        fi

        if [[ "$output_format" == "json" ]]; then
            echo "$cached_json"
        else
            local solution_data=$(echo "$cached_json" | jq '.key_concepts = (.key_concepts | split(", "))')
            display_pretty_solution "$solution_data"
        fi
        return 0
    fi

    # Solve new problem
    log "Solving new problem using URL..."
    local api_response=$(call_api "$image_url" "$hf_token")
    local json_response=$(echo "$api_response" | jq -r '.choices[0].message.content')

    if [[ -z "$json_response" || "$json_response" == "null" ]]; then
        log_error "Failed to get response from API"
        exit 1
    fi

    if ! echo "$json_response" | jq . >/dev/null 2>&1; then
        log_error "Invalid JSON response from API"
        exit 1
    fi

    # Save result
    local problem_id=$(generate_problem_id)
    save_solution "$problem_id" "$image_hash" "$topic" "$image_url" "$json_response"

    # Display
    if [[ "$output_format" == "json" ]]; then
        echo "$json_response"
    else
        display_pretty_solution "$json_response"
    fi
}

cmd_list() {
    local topic="$1"
    init_db
    list_problems "$topic"
}

cmd_show() {
    local problem_id="$1"
    if [[ -z "$problem_id" ]]; then
        log_error "Problem ID required"
        echo "Usage: $SCRIPT_NAME show <problem_id>"
        exit 1
    fi
    
    init_db
    local solution=$(get_solution "$problem_id")
    
    if [[ -z "$solution" || "$solution" == "{}" ]]; then
        log_error "Problem not found: $problem_id"
        exit 1
    fi
    
    # The solution is now a single JSON object, not an array
    local solution_data="$solution"
    
    # Convert key_concepts from string to array
    solution_data=$(echo "$solution_data" | jq '.key_concepts = (.key_concepts | split(", "))')
    
    display_pretty_solution "$solution_data"
}

cmd_search() {
    local query="$1"
    if [[ -z "$query" ]]; then
        log_error "Search query required"
        echo "Usage: $SCRIPT_NAME search <query>"
        exit 1
    fi
    
    init_db
    search_problems "$query"
}

cmd_topics() {
    init_db
    list_topics
}

cmd_stats() {
    init_db
    show_stats
}

cmd_export() {
    local format="$1"
    if [[ -z "$format" ]]; then
        log_error "Export format required"
        echo "Usage: $SCRIPT_NAME export <format>"
        echo "Available formats: json, sql"
        exit 1
    fi
    
    init_db
    export_solutions "$format"
}

# Main execution
main() {
    local command="$1"
    
    case "$command" in
        solve)
            shift
            cmd_solve "$@"
            ;;
        list)
            shift
            cmd_list "$@"
            ;;
        show)
            shift
            cmd_show "$@"
            ;;
        search)
            shift
            cmd_search "$@"
            ;;
        topics)
            shift
            cmd_topics "$@"
            ;;
        stats)
            shift
            cmd_stats "$@"
            ;;
        export)
            shift
            cmd_export "$@"
            ;;
        -h|--help)
            usage
            ;;
        -v|--version)
            echo -e "${BOLD}$SCRIPT_NAME${NC} v$SCRIPT_VERSION"
            ;;
        *)
            if [[ -z "$command" ]]; then
                log_error "No command specified"
                usage
                exit 1
            else
                log_error "Unknown command: $command"
                usage
                exit 1
            fi
            ;;
    esac
}

main "$@"