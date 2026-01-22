#!/usr/bin/env bash
#
# ralph-monitor.sh - Real-time monitor for Ralph/Claude output
#
# Watches the most recent JSON log file and displays readable text output.
# Run this in a separate terminal while ralph.sh is running.
#
# Usage: ./ralph-monitor.sh [path/to/.ralph]
#

set -euo pipefail

# Colors
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

# Default .ralph directory
RALPH_DIR="${1:-.ralph}"
LOGS_DIR="$RALPH_DIR/logs"

echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              Ralph Monitor - Real-time Output              ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}Watching:${NC} $LOGS_DIR"
echo -e "${DIM}Press Ctrl+C to exit${NC}"
echo ""

# Track which file we're following
current_file=""

while true; do
    # Find the most recent JSON log file
    latest_file=$(ls -t "$LOGS_DIR"/iter_*.json 2>/dev/null | head -1 || echo "")

    if [[ -z "$latest_file" ]]; then
        echo -e "${YELLOW}Waiting for log files...${NC}"
        sleep 2
        continue
    fi

    # If we found a new file, switch to it
    if [[ "$latest_file" != "$current_file" ]]; then
        current_file="$latest_file"
        echo ""
        echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${MAGENTA}Following: ${BOLD}$(basename "$current_file")${NC}"
        echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
    fi

    # Tail the file and parse JSON, extracting text from assistant messages
    tail -f "$current_file" 2>/dev/null | while IFS= read -r line; do
        # Skip empty lines
        [[ -z "$line" ]] && continue

        # Try to parse as JSON and extract relevant info
        msg_type=$(echo "$line" | jq -r '.type // empty' 2>/dev/null)

        case "$msg_type" in
            "assistant")
                # Extract text content from assistant messages
                text=$(echo "$line" | jq -r '
                    .message.content[]? |
                    select(.type=="text") |
                    .text // empty
                ' 2>/dev/null)

                if [[ -n "$text" ]]; then
                    echo -e "${GREEN}Claude:${NC}"
                    echo "$text"
                    echo ""
                fi

                # Also show tool use
                tool=$(echo "$line" | jq -r '
                    .message.content[]? |
                    select(.type=="tool_use") |
                    "  → Using tool: \(.name)"
                ' 2>/dev/null)

                if [[ -n "$tool" ]]; then
                    echo -e "${BLUE}$tool${NC}"
                fi
                ;;
            "user")
                # Show tool results briefly
                tool_result=$(echo "$line" | jq -r '
                    .message.content[]? |
                    select(.type=="tool_result") |
                    "  ← Tool result received"
                ' 2>/dev/null)

                if [[ -n "$tool_result" ]]; then
                    echo -e "${DIM}$tool_result${NC}"
                fi
                ;;
            "result")
                # Show final result
                result=$(echo "$line" | jq -r '.result // empty' 2>/dev/null)
                cost=$(echo "$line" | jq -r '.total_cost_usd // empty' 2>/dev/null)

                if [[ -n "$result" ]]; then
                    echo ""
                    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                    echo -e "${GREEN}Iteration Complete${NC}"
                    if [[ -n "$cost" ]]; then
                        echo -e "${CYAN}Cost: \$$cost${NC}"
                    fi
                    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                fi
                ;;
            "system")
                # Show init info
                subtype=$(echo "$line" | jq -r '.subtype // empty' 2>/dev/null)
                if [[ "$subtype" == "init" ]]; then
                    echo -e "${CYAN}Session initialized${NC}"
                fi
                ;;
        esac
    done &
    tail_pid=$!

    # Check every 2 seconds if there's a newer file
    while [[ "$(ls -t "$LOGS_DIR"/iter_*.json 2>/dev/null | head -1)" == "$current_file" ]]; do
        sleep 2
    done

    # Kill the tail process and switch to new file
    kill $tail_pid 2>/dev/null || true
done
