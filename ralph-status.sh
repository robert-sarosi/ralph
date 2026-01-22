#!/usr/bin/env bash
#
# ralph-status.sh - Real-time progress and cost tracker for Ralph
#
# Displays live progress, cost tracking, and task status.
# Run this in a separate terminal while ralph.sh is running.
#
# Usage: ./ralph-status.sh [path/to/.ralph] [plan-file]
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Arguments
RALPH_DIR="${1:-.ralph}"
PLAN_FILE="${2:-TASKS.md}"

STATE_FILE="$RALPH_DIR/state.json"
METRICS_FILE="$RALPH_DIR/metrics.json"

# Progress bar function
progress_bar() {
    local current=$1
    local total=$2
    local width=30

    if (( total == 0 )); then
        printf "[${DIM}%-${width}s${NC}] 0%%" ""
        return
    fi

    local pct=$((current * 100 / total))
    local filled=$((pct * width / 100))
    local empty=$((width - filled))

    printf "[${GREEN}"
    printf '█%.0s' $(seq 1 $filled 2>/dev/null) || true
    printf "${NC}${DIM}"
    printf '░%.0s' $(seq 1 $empty 2>/dev/null) || true
    printf "${NC}] %d%%" "$pct"
}

# Format duration
format_duration() {
    local seconds=$1
    if (( seconds < 60 )); then
        echo "${seconds}s"
    elif (( seconds < 3600 )); then
        echo "$((seconds / 60))m $((seconds % 60))s"
    else
        echo "$((seconds / 3600))h $((seconds % 3600 / 60))m"
    fi
}

# Main display function
display_status() {
    clear

    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║          Ralph Status - Progress & Cost Tracker            ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Check if state file exists
    if [[ ! -f "$STATE_FILE" ]]; then
        echo -e "${YELLOW}Waiting for Ralph session to start...${NC}"
        echo -e "${DIM}Looking for: $STATE_FILE${NC}"
        return
    fi

    # Session Info
    local session_id status iteration max_iterations started_at last_updated
    session_id=$(jq -r '.session_id // "unknown"' "$STATE_FILE" 2>/dev/null)
    status=$(jq -r '.status // "unknown"' "$STATE_FILE" 2>/dev/null)
    iteration=$(jq -r '.iteration // 0' "$STATE_FILE" 2>/dev/null)
    max_iterations=$(jq -r '.max_iterations // 0' "$STATE_FILE" 2>/dev/null)
    started_at=$(jq -r '.started_at // ""' "$STATE_FILE" 2>/dev/null)
    last_updated=$(jq -r '.last_updated // ""' "$STATE_FILE" 2>/dev/null)

    # Status color
    local status_color="$YELLOW"
    case "$status" in
        "running") status_color="$GREEN" ;;
        "completed") status_color="$GREEN" ;;
        "failed"|"error") status_color="$RED" ;;
    esac

    echo -e "${BOLD}Session${NC}"
    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  ${CYAN}ID:${NC}        $session_id"
    echo -e "  ${CYAN}Status:${NC}    ${status_color}${status}${NC}"
    echo -e "  ${CYAN}Iteration:${NC} $iteration / $max_iterations"
    printf "  ${CYAN}Progress:${NC}  "
    progress_bar "$iteration" "$max_iterations"
    echo ""
    echo ""

    # Metrics
    if [[ -f "$METRICS_FILE" ]]; then
        local input_tokens output_tokens total_tokens cost duration completed failed
        input_tokens=$(jq -r '.total_input_tokens // 0' "$METRICS_FILE" 2>/dev/null)
        output_tokens=$(jq -r '.total_output_tokens // 0' "$METRICS_FILE" 2>/dev/null)
        total_tokens=$(jq -r '.total_tokens // 0' "$METRICS_FILE" 2>/dev/null)
        cost=$(jq -r '.estimated_cost_usd // 0' "$METRICS_FILE" 2>/dev/null)
        duration=$(jq -r '.total_duration_seconds // 0' "$METRICS_FILE" 2>/dev/null)
        completed=$(jq -r '.iterations_completed // 0' "$METRICS_FILE" 2>/dev/null)
        failed=$(jq -r '.iterations_failed // 0' "$METRICS_FILE" 2>/dev/null)

        echo -e "${BOLD}Cost & Usage${NC}"
        echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo -e "  ${CYAN}Input Tokens:${NC}    $(printf "%'d" $input_tokens)"
        echo -e "  ${CYAN}Output Tokens:${NC}   $(printf "%'d" $output_tokens)"
        echo -e "  ${CYAN}Total Tokens:${NC}    $(printf "%'d" $total_tokens)"
        echo ""
        echo -e "  ${CYAN}Estimated Cost:${NC}  ${GREEN}\$${cost}${NC}"
        echo -e "  ${CYAN}Duration:${NC}        $(format_duration $duration)"
        echo ""
        echo -e "  ${CYAN}Completed:${NC}       ${GREEN}$completed${NC} iterations"
        if (( failed > 0 )); then
            echo -e "  ${CYAN}Failed:${NC}          ${RED}$failed${NC} iterations"
        fi
        echo ""

        # Cost per iteration
        if (( completed > 0 )); then
            local avg_cost avg_duration
            avg_cost=$(echo "scale=4; $cost / $completed" | bc 2>/dev/null || echo "0")
            avg_duration=$((duration / completed))
            echo -e "  ${DIM}Avg cost/iter:${NC}   ${DIM}\$${avg_cost}${NC}"
            echo -e "  ${DIM}Avg time/iter:${NC}   ${DIM}$(format_duration $avg_duration)${NC}"
        fi
        echo ""
    fi

    # Task Progress from plan file
    if [[ -f "$PLAN_FILE" ]]; then
        local total_tasks completed_tasks remaining_tasks
        total_tasks=$(grep -c '^\s*- \[' "$PLAN_FILE" 2>/dev/null || echo "0")
        completed_tasks=$(grep -c '^\s*- \[x\]' "$PLAN_FILE" 2>/dev/null || echo "0")
        # Sanitize to digits only and default to 0
        total_tasks=$(echo "$total_tasks" | tr -dc '0-9')
        completed_tasks=$(echo "$completed_tasks" | tr -dc '0-9')
        total_tasks=${total_tasks:-0}
        completed_tasks=${completed_tasks:-0}
        remaining_tasks=$((total_tasks - completed_tasks))

        echo -e "${BOLD}Tasks ($PLAN_FILE)${NC}"
        echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo -e "  ${CYAN}Total:${NC}       $total_tasks"
        echo -e "  ${CYAN}Completed:${NC}   ${GREEN}$completed_tasks${NC}"
        echo -e "  ${CYAN}Remaining:${NC}   ${YELLOW}$remaining_tasks${NC}"
        printf "  ${CYAN}Progress:${NC}    "
        progress_bar "$completed_tasks" "$total_tasks"
        echo ""
        echo ""

        # Show current/next task
        local current_task
        current_task=$(grep -m1 '^\s*- \[ \]' "$PLAN_FILE" 2>/dev/null | sed 's/^\s*- \[ \] //' | head -c 60 || echo "")
        if [[ -n "$current_task" ]]; then
            echo -e "  ${CYAN}Next task:${NC}"
            echo -e "  ${DIM}$current_task...${NC}"
        fi
        echo ""
    fi

    # PR Chunks (if defined)
    local chunk_count
    chunk_count=$(jq '.pr_chunks.chunks // [] | length' "$STATE_FILE" 2>/dev/null || echo "0")

    if [[ "$chunk_count" -gt 0 ]]; then
        local chunks_completed current_chunk
        chunks_completed=$(jq '.pr_chunks.chunks_completed // 0' "$STATE_FILE" 2>/dev/null)
        current_chunk=$(jq -r '.pr_chunks.current_chunk // "none"' "$STATE_FILE" 2>/dev/null)

        echo -e "${BOLD}PR Chunks${NC}"
        echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo -e "  ${CYAN}Total:${NC}     $chunk_count"
        echo -e "  ${CYAN}Completed:${NC} ${GREEN}$chunks_completed${NC}"
        printf "  ${CYAN}Progress:${NC}  "
        progress_bar "$chunks_completed" "$chunk_count"
        echo ""

        if [[ "$current_chunk" != "null" && "$current_chunk" != "none" ]]; then
            echo -e "  ${CYAN}Current:${NC}   ${MAGENTA}$current_chunk${NC}"
        fi
        echo ""

        # List chunks with status
        echo -e "  ${DIM}Chunks:${NC}"
        jq -r '.pr_chunks.chunks[] |
            if .completed then "    ✓ \(.name)"
            else "    ○ \(.name)" end' "$STATE_FILE" 2>/dev/null || true
        echo ""
    fi

    # Recent history
    if [[ -f "$METRICS_FILE" ]]; then
        local history_count
        history_count=$(jq '.history | length' "$METRICS_FILE" 2>/dev/null || echo "0")

        if (( history_count > 0 )); then
            echo -e "${BOLD}Recent Iterations${NC}"
            echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            jq -r '.history | .[-5:] | reverse | .[] |
                "  #\(.iteration): \(.duration_seconds)s, \(.input_tokens + .output_tokens) tokens, $\(.cost_usd)"
            ' "$METRICS_FILE" 2>/dev/null || true
            echo ""
        fi
    fi

    # Footer
    echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${DIM}Updated: $(date '+%Y-%m-%d %H:%M:%S') | Refresh: 3s | Ctrl+C to exit${NC}"
}

# Main loop
echo -e "${GREEN}Starting Ralph Status Monitor...${NC}"
echo -e "${DIM}Watching: $RALPH_DIR${NC}"
echo ""

while true; do
    display_status
    sleep 3
done
