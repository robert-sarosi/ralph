#!/usr/bin/env bash
#
# ralph.sh - MVP Ralph Loop for Claude Code
#
# An autonomous coding agent loop that repeatedly calls Claude Code
# until the task is complete. Based on the Ralph Wiggum pattern.
#
# Usage: ./ralph.sh <plan.md> [options]
#   <plan.md>               Task/PRD file (required, first argument)
#   -h, --help              Show help
#   -w, --worktree BRANCH   Create git worktree with feature branch
#   -b, --base BRANCH       Base branch for worktree (default: main)
#   -m, --max-iterations N  Maximum iterations (default: 10)
#   -r, --rate-limit N      Max calls per hour (default: 100)
#   -p, --prompt FILE       Prompt file (default: PROMPT.md)
#   -t, --timeout MIN       Timeout per call in minutes (default: 15)
#   -v, --verbose           Verbose output
#   --monitor               Run in tmux with log monitoring
#   --dry-run               Show what would run without executing
#   --reset                 Reset state and start fresh
#   --status                Show current status and exit

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

MAX_ITERATIONS=${MAX_ITERATIONS:-10}
RATE_LIMIT=${RATE_LIMIT:-100}
PROMPT_FILE=${PROMPT_FILE:-"PROMPT.md"}
PLAN_FILE=""  # Required, set via first positional argument
TIMEOUT_MINUTES=${TIMEOUT_MINUTES:-15}
MODEL=${MODEL:-"claude-opus-4-5-20251101"}
VERBOSE=${VERBOSE:-false}
DRY_RUN=${DRY_RUN:-false}
MONITOR_MODE=${MONITOR_MODE:-false}
FRESH_START=${FRESH_START:-false}
WORKTREE_BRANCH=""
BASE_BRANCH=${BASE_BRANCH:-"main"}

# Paths - will be set after worktree setup
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$PWD"

# State & persistence files (relative to WORK_DIR)
STATE_DIR=".ralph"
STATE_FILE=""
METRICS_FILE=""
LOG_DIR=""
RESPONSE_FILE=""
CALL_COUNT_FILE=""
CALL_HOUR_FILE=""
EXIT_SIGNALS_FILE=""

# Cost tracking (Claude Opus 4.5 pricing)
# Opus 4.5: $15/1M input, $75/1M output
COST_PER_1M_INPUT=${COST_PER_1M_INPUT:-15.00}
COST_PER_1M_OUTPUT=${COST_PER_1M_OUTPUT:-75.00}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# =============================================================================
# Utility Functions
# =============================================================================

log() {
    local level="$1"
    shift
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Output to stderr to avoid mixing with function return values
    case "$level" in
        INFO)  echo -e "${CYAN}[$timestamp]${NC} ${GREEN}INFO${NC}  $*" >&2 ;;
        WARN)  echo -e "${CYAN}[$timestamp]${NC} ${YELLOW}WARN${NC}  $*" >&2 ;;
        ERROR) echo -e "${CYAN}[$timestamp]${NC} ${RED}ERROR${NC} $*" >&2 ;;
        DEBUG) [[ "$VERBOSE" == "true" ]] && echo -e "${CYAN}[$timestamp]${NC} ${BLUE}DEBUG${NC} $*" >&2 ;;
    esac

    # Also append to session log (without colors)
    if [[ -n "$LOG_DIR" ]] && [[ -d "$LOG_DIR" ]]; then
        echo "[$timestamp] $level $*" >> "$LOG_DIR/session.log"
    fi
}

die() {
    log ERROR "$@"
    exit 1
}

ensure_jq() {
    if ! command -v jq &>/dev/null; then
        die "jq is required but not installed. Install with: brew install jq"
    fi
}

ensure_tmux() {
    if ! command -v tmux &>/dev/null; then
        die "tmux is required for --monitor mode. Install with: brew install tmux"
    fi
}

init_state_paths() {
    STATE_FILE="$STATE_DIR/state.json"
    METRICS_FILE="$STATE_DIR/metrics.json"
    LOG_DIR="$STATE_DIR/logs"
    RESPONSE_FILE="$STATE_DIR/last_response"
    CALL_COUNT_FILE="$STATE_DIR/call_count"
    CALL_HOUR_FILE="$STATE_DIR/call_hour"
    EXIT_SIGNALS_FILE="$STATE_DIR/exit_signals"
}

usage() {
    cat << EOF
ralph.sh - MVP Ralph Loop for Claude Code

Usage: ./ralph.sh <plan.md> [options]

Arguments:
  <plan.md>               Task/PRD file with markdown checklist (required)

Options:
  -h, --help              Show this help message
  -w, --worktree BRANCH   Create git worktree with feature branch name
  -b, --base BRANCH       Base branch for worktree (default: main)
  -m, --max-iterations N  Maximum iterations (default: $MAX_ITERATIONS)
  -r, --rate-limit N      Max calls per hour (default: $RATE_LIMIT)
  -p, --prompt FILE       Prompt file (default: $PROMPT_FILE)
  -t, --timeout MIN       Timeout per call in minutes (default: $TIMEOUT_MINUTES)
  -M, --model MODEL       Claude model to use (default: $MODEL)
  -v, --verbose           Verbose output
  --monitor               Run in tmux session with log monitoring panes
  --fresh                 Reset state and start fresh (use with --monitor)
  --dry-run               Show what would run without executing
  --reset                 Reset all state and exit (interactive reset)
  --status                Show current status and exit

Worktree Mode:
  When using -w/--worktree, ralph will:
  1. Create a git worktree at ../<branch-name> from the base branch
  2. Copy PROMPT.md and plan file into the worktree
  3. Run the loop inside the worktree

  This is designed for bare repo setups where you run ralph from the
  main checkout and it creates isolated worktrees for each feature.

Monitor Mode (--monitor):
  Launches ralph in a tmux session with:
  - Main pane: Ralph loop execution
  - Right pane: Live log tail
  - Bottom pane: Status updates

  Attach with: tmux attach -t ralph-<session_id>

Setup:
  1. Create PROMPT.md with development instructions
  2. Create a plan file (e.g., plan.md) with your tasks:

     ## Tasks
     - [ ] First task to complete
     - [ ] Second task to complete
     - [ ] Third task to complete

  3. Run: ./ralph.sh plan.md
     Or with worktree: ./ralph.sh plan.md -w feature/my-feature

State Files (in .ralph/):
  state.json      - Iteration count, timestamps, resume info
  metrics.json    - Token usage, costs, timing
  logs/           - Per-iteration logs and session log
  exit_signals    - Rolling window of exit signals for detection

Exit Codes:
  0  Task completed successfully
  1  Error or max iterations reached
  2  Rate limit exceeded

Examples:
  ./ralph.sh plan.md                                # Run with plan file
  ./ralph.sh plan.md -w feature/auth -m 20          # Worktree + 20 iterations
  ./ralph.sh plan.md --monitor                      # Run with tmux monitoring
  ./ralph.sh plan.md -w feat/i18n --monitor         # Worktree + monitor
  ./ralph.sh plan.md -w feat/i18n --monitor --fresh # Fresh start in worktree
  ./ralph.sh plan.md --status                       # Check progress
  ./ralph.sh plan.md --reset                        # Reset and exit

EOF
    exit 0
}

# =============================================================================
# Git Worktree Management
# =============================================================================

setup_worktree() {
    local branch="$1"
    local base="$2"

    log INFO "Setting up git worktree for branch: $branch"

    # Determine worktree path (subdirectory of current repo)
    # Convert branch name to safe directory name (replace / with -)
    local worktree_name="${branch//\//-}"
    local worktree_path="$PWD/$worktree_name"

    # Check if we're in a git repo
    if ! git rev-parse --git-dir &>/dev/null; then
        die "Not in a git repository. Worktree mode requires git."
    fi

    # Check if worktree already exists
    if [[ -d "$worktree_path" ]]; then
        log INFO "Worktree already exists at: $worktree_path"

        # Verify it's a valid worktree
        if git worktree list | grep -q "$worktree_path"; then
            log INFO "Using existing worktree"
        else
            die "Directory exists but is not a git worktree: $worktree_path"
        fi
    else
        # Fetch latest from remote
        log INFO "Fetching latest from remote..."
        git fetch origin "$base" 2>/dev/null || log WARN "Could not fetch origin/$base"

        # Check if branch already exists
        if git show-ref --verify --quiet "refs/heads/$branch"; then
            log INFO "Branch '$branch' exists, creating worktree..."
            git worktree add "$worktree_path" "$branch"
        else
            log INFO "Creating new branch '$branch' from '$base'..."
            git worktree add -b "$branch" "$worktree_path" "origin/$base" 2>/dev/null || \
                git worktree add -b "$branch" "$worktree_path" "$base"
        fi

        log INFO "Created worktree at: $worktree_path"
    fi

    # Copy required files to worktree if they don't exist
    local src_prompt="$SCRIPT_DIR/$PROMPT_FILE"
    local src_plan="$SCRIPT_DIR/$PLAN_FILE"
    local dst_prompt="$worktree_path/$PROMPT_FILE"
    local dst_plan="$worktree_path/$PLAN_FILE"

    if [[ -f "$src_prompt" ]] && [[ ! -f "$dst_prompt" ]]; then
        cp "$src_prompt" "$dst_prompt"
        log INFO "Copied $PROMPT_FILE to worktree"
    fi

    if [[ -f "$src_plan" ]] && [[ ! -f "$dst_plan" ]]; then
        cp "$src_plan" "$dst_plan"
        log INFO "Copied $PLAN_FILE to worktree"
    fi

    # Change to worktree directory
    cd "$worktree_path"
    WORK_DIR="$worktree_path"

    log INFO "Working directory: $WORK_DIR"
    log INFO "Branch: $(git branch --show-current)"
}

# =============================================================================
# Tmux Monitor Mode
# =============================================================================

run_in_tmux() {
    # Generate a memorable session name
    local session_name
    if [[ -n "$WORKTREE_BRANCH" ]]; then
        # Use branch name for session (replace / with -)
        session_name="ralph-${WORKTREE_BRANCH//\//-}"
    else
        session_name="ralph-$(basename "$WORK_DIR")-$(date '+%H%M')"
    fi

    # Check if session already exists
    if tmux has-session -t "$session_name" 2>/dev/null; then
        echo ""
        echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║           Existing Ralph Session Found                       ║${NC}"
        echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${BOLD}Session:${NC} $session_name"
        echo ""
        echo -e "${CYAN}Attaching to existing session...${NC}"
        echo ""
        echo -e "  ${BOLD}tmux attach -t $session_name${NC}"
        echo ""
        sleep 1
        exec tmux attach -t "$session_name"
    fi

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              Starting Ralph Monitor Session                  ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BOLD}Session:${NC}   $session_name"
    echo -e "${BOLD}Directory:${NC} $WORK_DIR"
    [[ -n "$WORKTREE_BRANCH" ]] && echo -e "${BOLD}Branch:${NC}    $WORKTREE_BRANCH"
    echo ""
    echo -e "${CYAN}Commands:${NC}"
    echo -e "  Attach:  ${BOLD}tmux attach -t $session_name${NC}"
    echo -e "  Detach:  ${BOLD}Ctrl+B, then D${NC}"
    echo -e "  Kill:    ${BOLD}tmux kill-session -t $session_name${NC}"
    echo ""
    echo -e "${GREEN}Auto-attaching in 2 seconds...${NC}"
    sleep 2

    # Build the ralph command WITHOUT --monitor and WITHOUT -w (worktree already set up)
    local ralph_cmd="$SCRIPT_DIR/ralph.sh"
    local ralph_args=()

    [[ -n "$PLAN_FILE" ]] && ralph_args+=("$PLAN_FILE")
    # NOTE: Don't pass -w here since worktree is already set up and we're in it
    ralph_args+=("-m" "$MAX_ITERATIONS")
    ralph_args+=("-r" "$RATE_LIMIT")
    ralph_args+=("-p" "$PROMPT_FILE")
    ralph_args+=("-t" "$TIMEOUT_MINUTES")
    ralph_args+=("-M" "$MODEL")
    [[ "$VERBOSE" == "true" ]] && ralph_args+=("-v")
    [[ "$FRESH_START" == "true" ]] && ralph_args+=("--fresh")
    [[ "$DRY_RUN" == "true" ]] && ralph_args+=("--dry-run")

    # Create tmux session with main pane
    tmux new-session -d -s "$session_name" -c "$WORK_DIR"

    # Set up the layout
    # Split vertically (left/right) - 70/30
    tmux split-window -h -p 30 -t "$session_name"

    # Split the right pane horizontally (top/bottom) - 70/30
    tmux split-window -v -p 30 -t "$session_name:0.1"

    # Pane 0 (left, main): Ralph loop
    # Pane 1 (right top): Log tail
    # Pane 2 (right bottom): Status watch

    # Initialize state directory first so logs exist
    mkdir -p "$WORK_DIR/.ralph/logs"
    touch "$WORK_DIR/.ralph/logs/session.log"

    # Set up Claude output tail in pane 1 (follows latest JSON log, filters through jq for readability)
    tmux send-keys -t "$session_name:0.1" "cd '$WORK_DIR' && echo 'Watching for Claude output...' && while true; do f=\$(ls -t .ralph/logs/iter_*.json 2>/dev/null | head -1); if [[ -n \"\$f\" ]]; then echo \"=== Following: \$f ===\"; tail -f \"\$f\" 2>/dev/null | jq -r 'select(.type==\"assistant\") | .message.content[]? | select(.type==\"text\") | .text // empty' 2>/dev/null & pid=\$!; while [[ \"\$(ls -t .ralph/logs/iter_*.json 2>/dev/null | head -1)\" == \"\$f\" ]]; do sleep 2; done; kill \$pid 2>/dev/null; fi; sleep 1; done" C-m

    # Set up status watch in pane 2 (use while loop as fallback for missing 'watch' command)
    tmux send-keys -t "$session_name:0.2" "cd '$WORK_DIR' && while true; do clear; '$ralph_cmd' '$PLAN_FILE' --status 2>/dev/null || echo 'Waiting for session to start...'; sleep 5; done" C-m

    # Run ralph in pane 0 (main)
    tmux send-keys -t "$session_name:0.0" "cd '$WORK_DIR' && '$ralph_cmd' ${ralph_args[*]}" C-m

    # Set pane titles
    tmux select-pane -t "$session_name:0.0" -T "Ralph Loop"
    tmux select-pane -t "$session_name:0.1" -T "Claude Output"
    tmux select-pane -t "$session_name:0.2" -T "Status"

    # Enable pane borders with titles
    tmux set-option -t "$session_name" pane-border-status top
    tmux set-option -t "$session_name" pane-border-format "#{pane_title}"

    # Select main pane
    tmux select-pane -t "$session_name:0.0"

    # Auto-attach to the session
    exec tmux attach -t "$session_name"
}

# =============================================================================
# State Management (Survives Restarts)
# =============================================================================

init_state_dir() {
    mkdir -p "$STATE_DIR"
    mkdir -p "$LOG_DIR"

    # Initialize state file if doesn't exist
    if [[ ! -f "$STATE_FILE" ]]; then
        cat > "$STATE_FILE" << EOF
{
  "session_id": "$(date '+%Y%m%d_%H%M%S')_$$",
  "started_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "iteration": 0,
  "max_iterations": $MAX_ITERATIONS,
  "prompt_file": "$PROMPT_FILE",
  "plan_file": "$PLAN_FILE",
  "worktree_branch": "${WORKTREE_BRANCH:-null}",
  "status": "running",
  "last_updated": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF
        log INFO "Created new session: $(jq -r '.session_id' "$STATE_FILE")"
    fi

    # Initialize metrics file if doesn't exist
    if [[ ! -f "$METRICS_FILE" ]]; then
        cat > "$METRICS_FILE" << EOF
{
  "total_input_tokens": 0,
  "total_output_tokens": 0,
  "total_tokens": 0,
  "estimated_cost_usd": 0.0,
  "iterations_completed": 0,
  "iterations_failed": 0,
  "total_duration_seconds": 0,
  "history": []
}
EOF
    fi

    # Initialize exit signals file
    if [[ ! -f "$EXIT_SIGNALS_FILE" ]]; then
        echo "[]" > "$EXIT_SIGNALS_FILE"
    fi
}

get_state() {
    local key="$1"
    jq -r ".$key // empty" "$STATE_FILE"
}

set_state() {
    local key="$1"
    local value="$2"
    local tmp
    tmp=$(mktemp)
    jq ".$key = $value | .last_updated = \"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\"" "$STATE_FILE" > "$tmp"
    mv "$tmp" "$STATE_FILE"
}

get_iteration() {
    get_state "iteration"
}

set_iteration() {
    set_state "iteration" "$1"
}

reset_state() {
    log WARN "Resetting all state..."
    rm -rf "$STATE_DIR"
    log INFO "State reset complete. Run again to start fresh."
    exit 0
}

show_status() {
    init_state_paths

    if [[ ! -f "$STATE_FILE" ]]; then
        echo "No active session found. Run ./ralph.sh to start."
        exit 0
    fi

    echo -e "${BOLD}Ralph Loop Status${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${CYAN}Session:${NC}     $(get_state 'session_id')"
    echo -e "${CYAN}Started:${NC}     $(get_state 'started_at')"
    echo -e "${CYAN}Status:${NC}      $(get_state 'status')"
    echo -e "${CYAN}Iteration:${NC}   $(get_state 'iteration') / $(get_state 'max_iterations')"

    local wt_branch
    wt_branch=$(get_state 'worktree_branch')
    if [[ -n "$wt_branch" ]] && [[ "$wt_branch" != "null" ]]; then
        echo -e "${CYAN}Worktree:${NC}    $wt_branch"
    fi
    echo ""

    if [[ -f "$METRICS_FILE" ]]; then
        echo -e "${BOLD}Metrics${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo -e "${CYAN}Input tokens:${NC}   $(jq '.total_input_tokens' "$METRICS_FILE")"
        echo -e "${CYAN}Output tokens:${NC}  $(jq '.total_output_tokens' "$METRICS_FILE")"
        echo -e "${CYAN}Total tokens:${NC}   $(jq '.total_tokens' "$METRICS_FILE")"
        echo -e "${CYAN}Est. cost:${NC}      \$$(jq '.estimated_cost_usd' "$METRICS_FILE")"
        echo -e "${CYAN}Completed:${NC}      $(jq '.iterations_completed' "$METRICS_FILE") iterations"
        echo -e "${CYAN}Failed:${NC}         $(jq '.iterations_failed' "$METRICS_FILE") iterations"
    fi
    echo ""

    if [[ -f "$PLAN_FILE" ]]; then
        local total_tasks completed_tasks remaining_tasks
        total_tasks=$(grep -c '^\s*- \[' "$PLAN_FILE" 2>/dev/null || echo "0")
        completed_tasks=$(grep -c '^\s*- \[x\]' "$PLAN_FILE" 2>/dev/null || echo "0")
        remaining_tasks=$((total_tasks - completed_tasks))

        echo -e "${BOLD}Tasks ($PLAN_FILE)${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo -e "${CYAN}Total:${NC}       $total_tasks"
        echo -e "${CYAN}Completed:${NC}   $completed_tasks"
        echo -e "${CYAN}Remaining:${NC}   $remaining_tasks"

        # Progress bar
        if (( total_tasks > 0 )); then
            local pct=$((completed_tasks * 100 / total_tasks))
            local filled=$((pct / 5))
            local empty=$((20 - filled))
            printf "${CYAN}Progress:${NC}    [${GREEN}"
            printf '█%.0s' $(seq 1 $filled 2>/dev/null) || true
            printf "${NC}"
            printf '░%.0s' $(seq 1 $empty 2>/dev/null) || true
            printf "] %d%%\n" "$pct"
        fi
    fi

    # PR Chunks status
    if [[ -f "$STATE_FILE" ]]; then
        local chunk_count
        chunk_count=$(jq '.pr_chunks.chunks // [] | length' "$STATE_FILE" 2>/dev/null || echo "0")

        if [[ "$chunk_count" -gt 0 ]]; then
            local chunks_completed current_chunk
            chunks_completed=$(jq '.pr_chunks.chunks_completed // 0' "$STATE_FILE")
            current_chunk=$(jq -r '.pr_chunks.current_chunk // "none"' "$STATE_FILE")

            echo ""
            echo -e "${BOLD}PR Chunks${NC}"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo -e "${CYAN}Total:${NC}       $chunk_count"
            echo -e "${CYAN}Completed:${NC}   $chunks_completed"
            if [[ "$current_chunk" != "null" && "$current_chunk" != "none" ]]; then
                echo -e "${CYAN}Current:${NC}     $current_chunk"
            else
                echo -e "${CYAN}Current:${NC}     (all complete)"
            fi

            # List all chunks with status
            echo ""
            jq -r '.pr_chunks.chunks[] |
                if .completed then "  ✓ \(.name) (\(.tasks | join(", ")))"
                else "  ○ \(.name) (\(.tasks | join(", ")))" end' "$STATE_FILE" 2>/dev/null || true
        fi
    fi

    exit 0
}

# =============================================================================
# Metrics & Cost Tracking
# =============================================================================

update_metrics() {
    local input_tokens="${1:-0}"
    local output_tokens="${2:-0}"
    local duration_seconds="${3:-0}"
    local success="${4:-true}"

    local total_tokens=$((input_tokens + output_tokens))

    # Calculate cost
    local input_cost output_cost iteration_cost
    input_cost=$(echo "scale=6; $input_tokens * $COST_PER_1M_INPUT / 1000000" | bc)
    output_cost=$(echo "scale=6; $output_tokens * $COST_PER_1M_OUTPUT / 1000000" | bc)
    iteration_cost=$(echo "scale=6; $input_cost + $output_cost" | bc)

    # Update metrics file
    local tmp
    tmp=$(mktemp)

    local iteration
    iteration=$(get_iteration)

    jq --argjson input "$input_tokens" \
       --argjson output "$output_tokens" \
       --argjson total "$total_tokens" \
       --argjson cost "$iteration_cost" \
       --argjson duration "$duration_seconds" \
       --argjson iter "$iteration" \
       --arg success "$success" \
       --arg timestamp "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
       '
       .total_input_tokens += $input |
       .total_output_tokens += $output |
       .total_tokens += $total |
       .estimated_cost_usd = ((.estimated_cost_usd + $cost) * 1000000 | round | . / 1000000) |
       .total_duration_seconds += $duration |
       (if $success == "true" then .iterations_completed += 1 else .iterations_failed += 1 end) |
       .history += [{
         "iteration": $iter,
         "timestamp": $timestamp,
         "input_tokens": $input,
         "output_tokens": $output,
         "cost_usd": $cost,
         "duration_seconds": $duration,
         "success": ($success == "true")
       }]
       ' "$METRICS_FILE" > "$tmp"
    mv "$tmp" "$METRICS_FILE"

    log DEBUG "Tokens: +$input_tokens in, +$output_tokens out | Cost: +\$$iteration_cost"
}

parse_token_usage() {
    local response_file="$1"

    # Claude Code with --output-format stream-json outputs usage info
    local input_tokens=0
    local output_tokens=0

    # Try to extract from JSON output using jq (more reliable)
    if command -v jq &>/dev/null && [[ -f "$response_file" ]]; then
        # Get the last result message with usage data
        local usage_json
        usage_json=$(grep '"usage"' "$response_file" 2>/dev/null | tail -1 || echo "")

        if [[ -n "$usage_json" ]]; then
            input_tokens=$(echo "$usage_json" | jq -r '.usage.input_tokens // .usage.cache_read_input_tokens // 0' 2>/dev/null || echo "0")
            output_tokens=$(echo "$usage_json" | jq -r '.usage.output_tokens // 0' 2>/dev/null || echo "0")

            # Handle case where jq returns empty or null
            [[ "$input_tokens" == "null" || -z "$input_tokens" ]] && input_tokens=0
            [[ "$output_tokens" == "null" || -z "$output_tokens" ]] && output_tokens=0
        fi
    fi

    # Fallback: try grep if jq didn't work
    if [[ "$input_tokens" == "0" ]] && [[ "$output_tokens" == "0" ]]; then
        if grep -q '"input_tokens"' "$response_file" 2>/dev/null; then
            input_tokens=$(grep -o '"input_tokens":[0-9]*' "$response_file" | tail -1 | grep -o '[0-9]*' || echo "0")
            output_tokens=$(grep -o '"output_tokens":[0-9]*' "$response_file" | tail -1 | grep -o '[0-9]*' || echo "0")
        fi
    fi

    # Last resort: estimate from response size
    if [[ "$input_tokens" == "0" ]] && [[ "$output_tokens" == "0" ]]; then
        local response_chars
        response_chars=$(wc -c < "$response_file" 2>/dev/null | tr -d ' ' || echo "0")
        output_tokens=$((response_chars / 4))

        if [[ -f "$PROMPT_FILE" ]]; then
            local prompt_chars
            prompt_chars=$(wc -c < "$PROMPT_FILE" | tr -d ' ')
            input_tokens=$((prompt_chars / 4))
        fi

        log DEBUG "Token usage estimated (no JSON data): ~$input_tokens in, ~$output_tokens out"
    else
        log DEBUG "Token usage from JSON: $input_tokens in, $output_tokens out"
    fi

    echo "$input_tokens $output_tokens"
}

# =============================================================================
# Rate Limiting
# =============================================================================

check_rate_limit() {
    local current_hour
    current_hour=$(date '+%Y%m%d%H')

    # Reset counter if hour changed
    if [[ -f "$CALL_HOUR_FILE" ]]; then
        local stored_hour
        stored_hour=$(cat "$CALL_HOUR_FILE")
        if [[ "$stored_hour" != "$current_hour" ]]; then
            echo "0" > "$CALL_COUNT_FILE"
            echo "$current_hour" > "$CALL_HOUR_FILE"
            log DEBUG "Rate limit reset for new hour"
        fi
    else
        echo "0" > "$CALL_COUNT_FILE"
        echo "$current_hour" > "$CALL_HOUR_FILE"
    fi

    # Check current count
    local count=0
    [[ -f "$CALL_COUNT_FILE" ]] && count=$(cat "$CALL_COUNT_FILE")

    if (( count >= RATE_LIMIT )); then
        local minutes_until_reset
        minutes_until_reset=$(( 60 - $(date '+%M') ))
        log WARN "Rate limit ($RATE_LIMIT/hour) reached. Reset in ${minutes_until_reset} minutes."
        return 1
    fi

    # Increment counter
    echo $(( count + 1 )) > "$CALL_COUNT_FILE"
    log DEBUG "Rate limit: $(( count + 1 ))/$RATE_LIMIT calls this hour"
    return 0
}

# =============================================================================
# Exit Signal Detection (Dual-Condition Gate)
# =============================================================================

# Completion indicator patterns
COMPLETION_PATTERNS=(
    "<promise>COMPLETE</promise>"
    "EXIT_SIGNAL: true"
)

# Check for the primary completion signal: <promise>COMPLETE</promise>
check_promise_complete() {
    local response_file="$1"
    if grep -q "<promise>COMPLETE</promise>" "$response_file" 2>/dev/null; then
        return 0
    fi
    return 1
}

count_completion_indicators() {
    local response_file="$1"
    local count=0
    local response_lower
    response_lower=$(tr '[:upper:]' '[:lower:]' < "$response_file")

    for pattern in "${COMPLETION_PATTERNS[@]}"; do
        if echo "$response_lower" | grep -qi "$pattern"; then
            count=$((count + 1))
        fi
    done

    echo "$count"
}

# =============================================================================
# PR Chunk Management
# =============================================================================

# Parse plan file for PR chunk markers
# Returns JSON array of chunks with task boundaries
parse_pr_chunks() {
    local plan_file="$1"

    if [[ ! -f "$plan_file" ]]; then
        echo "[]"
        return
    fi

    # Use awk to parse PR markers and tasks (BSD awk compatible)
    awk '
    BEGIN {
        chunk_name = "default"
        chunk_start = ""
        tasks = ""
        chunks = "["
        first_chunk = 1
    }

    # Match PR marker: <!-- PR: name -->
    /<!--[[:space:]]*PR:[[:space:]]*[^>]+[[:space:]]*-->/ {
        # Extract PR name (BSD awk compatible)
        new_chunk = $0
        gsub(/.*<!--[[:space:]]*PR:[[:space:]]*/, "", new_chunk)
        gsub(/[[:space:]]*-->.*/, "", new_chunk)
        gsub(/^[[:space:]]+/, "", new_chunk)
        gsub(/[[:space:]]+$/, "", new_chunk)

        # Close previous chunk if it had tasks
        if (chunk_start != "" && tasks != "") {
            if (!first_chunk) chunks = chunks ","
            chunks = chunks "{\"name\":\"" chunk_name "\",\"start_task\":\"" chunk_start "\",\"tasks\":[" tasks "]}"
            first_chunk = 0
        }

        chunk_name = new_chunk
        chunk_start = ""
        tasks = ""
    }

    # Match task marker: ### T-XXX or ### US-XXX
    /^###[[:space:]]+(T-[0-9]+|US-[0-9]+):/ {
        # Extract task ID (BSD awk compatible)
        task_id = $0
        gsub(/^###[[:space:]]+/, "", task_id)
        gsub(/:.*$/, "", task_id)

        if (chunk_start == "") {
            chunk_start = task_id
        }

        if (tasks != "") tasks = tasks ","
        tasks = tasks "\"" task_id "\""
    }

    END {
        # Close final chunk
        if (chunk_start != "" && tasks != "") {
            if (!first_chunk) chunks = chunks ","
            chunks = chunks "{\"name\":\"" chunk_name "\",\"start_task\":\"" chunk_start "\",\"tasks\":[" tasks "]}"
        }
        chunks = chunks "]"
        print chunks
    }
    ' "$plan_file"
}

# Initialize PR chunk state
init_pr_chunks() {
    local chunks_json
    chunks_json=$(parse_pr_chunks "$PLAN_FILE")

    # Skip if no chunks found
    local chunk_count
    chunk_count=$(echo "$chunks_json" | jq 'length')
    if [[ "$chunk_count" -eq 0 ]]; then
        log DEBUG "No PR chunks defined in plan file"
        return
    fi

    # Update state with chunk info
    local tmp
    tmp=$(mktemp)
    jq --argjson chunks "$chunks_json" '
        .pr_chunks = {
            "chunks": $chunks,
            "current_chunk_index": 0,
            "chunks_completed": 0,
            "last_chunk_completed_at": null
        } |
        if ($chunks | length) > 0 then
            .pr_chunks.current_chunk = $chunks[0].name
        else
            .pr_chunks.current_chunk = null
        end
    ' "$STATE_FILE" > "$tmp"
    mv "$tmp" "$STATE_FILE"

    log INFO "Found $chunk_count PR chunk(s) in plan"
}

# Check if chunk is complete (all tasks in chunk are marked [x])
check_chunk_completion() {
    local chunk_name="$1"

    # Get tasks in this chunk
    local tasks
    tasks=$(jq -r --arg chunk "$chunk_name" '
        .pr_chunks.chunks[] | select(.name == $chunk) | .tasks[]
    ' "$STATE_FILE" 2>/dev/null)

    if [[ -z "$tasks" ]]; then
        return 1
    fi

    # Check each task in plan file - look for **Status:** [x] pattern
    local all_complete=true
    while IFS= read -r task_id; do
        # Find the task section and check its status
        if ! grep -A 5 "^### $task_id:" "$PLAN_FILE" 2>/dev/null | grep -q '\[x\]'; then
            all_complete=false
            break
        fi
    done <<< "$tasks"

    [[ "$all_complete" == "true" ]]
}

# Mark chunk as complete and notify
complete_chunk() {
    local chunk_name="$1"

    local tmp
    tmp=$(mktemp)

    # Update state
    jq --arg chunk "$chunk_name" \
       --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
        .pr_chunks.chunks = [
            .pr_chunks.chunks[] |
            if .name == $chunk then . + {"completed": true} else . end
        ] |
        .pr_chunks.chunks_completed += 1 |
        .pr_chunks.last_chunk_completed_at = $ts |
        .pr_chunks.current_chunk_index += 1 |
        if .pr_chunks.current_chunk_index < (.pr_chunks.chunks | length) then
            .pr_chunks.current_chunk = .pr_chunks.chunks[.pr_chunks.current_chunk_index].name
        else
            .pr_chunks.current_chunk = null
        end
    ' "$STATE_FILE" > "$tmp"
    mv "$tmp" "$STATE_FILE"

    # Get tasks in completed chunk for notification
    local tasks
    tasks=$(jq -r --arg chunk "$chunk_name" '
        .pr_chunks.chunks[] | select(.name == $chunk) | .tasks | join(", ")
    ' "$STATE_FILE")

    # Log notification
    log INFO "PR_CHUNK_COMPLETE $chunk_name tasks=$tasks iteration=$(get_iteration)"

    # User notification
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN} PR CHUNK COMPLETE: ${BOLD}$chunk_name${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e " Tasks completed: ${CYAN}$tasks${NC}"
    echo -e " ${MAGENTA}Ready for PR review${NC}"

    # Show next chunk if exists
    local next_chunk
    next_chunk=$(jq -r '.pr_chunks.current_chunk // "none"' "$STATE_FILE")
    if [[ "$next_chunk" != "null" && "$next_chunk" != "none" ]]; then
        local next_tasks
        next_tasks=$(jq -r --arg chunk "$next_chunk" '
            .pr_chunks.chunks[] | select(.name == $chunk) | .tasks | join(", ")
        ' "$STATE_FILE")
        echo -e " Continuing to next chunk: ${BOLD}$next_chunk${NC} ($next_tasks)"
    else
        echo -e " ${GREEN}All PR chunks complete!${NC}"
    fi
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# Check if current chunk is complete after task completion
check_and_notify_chunk_completion() {
    # Check if pr_chunks is defined in state
    local has_chunks
    has_chunks=$(jq '.pr_chunks.chunks // [] | length' "$STATE_FILE" 2>/dev/null || echo "0")

    if [[ "$has_chunks" == "0" ]]; then
        return 0  # No chunks defined
    fi

    local current_chunk
    current_chunk=$(jq -r '.pr_chunks.current_chunk // empty' "$STATE_FILE")

    if [[ -z "$current_chunk" || "$current_chunk" == "null" ]]; then
        return 0  # No current chunk (all done or not initialized)
    fi

    # Check if already completed
    local already_completed
    already_completed=$(jq -r --arg chunk "$current_chunk" '
        .pr_chunks.chunks[] | select(.name == $chunk) | .completed // false
    ' "$STATE_FILE")

    if [[ "$already_completed" == "true" ]]; then
        return 0  # Already marked complete
    fi

    if check_chunk_completion "$current_chunk"; then
        complete_chunk "$current_chunk"
    fi
}

parse_ralph_status() {
    local response_file="$1"

    # Convert escaped \n to real newlines (JSON stream format escapes them)
    local normalized_content
    normalized_content=$(sed 's/\\n/\
/g' "$response_file" 2>/dev/null)

    # Extract the LAST RALPH_STATUS block (in case Claude outputs multiple)
    local status_block
    status_block=$(echo "$normalized_content" | awk '/---RALPH_STATUS---/{p=1; block=""} p{block=block $0 "\n"} /---END_RALPH_STATUS---/{p=0; last=block} END{printf "%s", last}' 2>/dev/null || echo "")

    if [[ -z "$status_block" ]]; then
        log WARN "No RALPH_STATUS block found in response"
        echo "STATUS=UNKNOWN"
        echo "EXIT_SIGNAL=false"
        echo "TASKS_REMAINING=unknown"
        echo "COMPLETION_INDICATORS=0"
        return 1
    fi

    # Parse fields
    local status exit_signal tasks_remaining tasks_completed files_modified tests_status work_type recommendation pr_chunk_complete

    # Use head -1 to only take the first match (in case of multiple RALPH_STATUS blocks)
    status=$(echo "$status_block" | grep -E "^STATUS:" | head -1 | sed 's/STATUS:[[:space:]]*//' | tr -d '\r' | xargs)
    exit_signal=$(echo "$status_block" | grep -E "^EXIT_SIGNAL:" | head -1 | sed 's/EXIT_SIGNAL:[[:space:]]*//' | tr -d '\r' | xargs)
    tasks_remaining=$(echo "$status_block" | grep -E "^TASKS_REMAINING:" | head -1 | sed 's/TASKS_REMAINING:[[:space:]]*//' | tr -d '\r' | xargs)
    tasks_completed=$(echo "$status_block" | grep -E "^TASKS_COMPLETED_THIS_LOOP:" | head -1 | sed 's/TASKS_COMPLETED_THIS_LOOP:[[:space:]]*//' | tr -d '\r' | xargs)
    files_modified=$(echo "$status_block" | grep -E "^FILES_MODIFIED:" | head -1 | sed 's/FILES_MODIFIED:[[:space:]]*//' | tr -d '\r' | xargs)
    tests_status=$(echo "$status_block" | grep -E "^TESTS_STATUS:" | head -1 | sed 's/TESTS_STATUS:[[:space:]]*//' | tr -d '\r' | xargs)
    work_type=$(echo "$status_block" | grep -E "^WORK_TYPE:" | head -1 | sed 's/WORK_TYPE:[[:space:]]*//' | tr -d '\r' | xargs)
    recommendation=$(echo "$status_block" | grep -E "^RECOMMENDATION:" | head -1 | sed 's/RECOMMENDATION:[[:space:]]*//' | tr -d '\r')
    pr_chunk_complete=$(echo "$status_block" | grep -E "^PR_CHUNK_COMPLETE:" | head -1 | sed 's/PR_CHUNK_COMPLETE:[[:space:]]*//' | tr -d '\r' | xargs)

    # Count completion indicators
    local completion_indicators
    completion_indicators=$(count_completion_indicators "$response_file")

    # Output parsed values (properly quoted for eval)
    echo "STATUS='${status:-UNKNOWN}'"
    echo "EXIT_SIGNAL='${exit_signal:-false}'"
    echo "TASKS_REMAINING='${tasks_remaining:-unknown}'"
    echo "TASKS_COMPLETED='${tasks_completed:-0}'"
    echo "FILES_MODIFIED='${files_modified:-0}'"
    echo "TESTS_STATUS='${tests_status:-NOT_RUN}'"
    echo "WORK_TYPE='${work_type:-UNKNOWN}'"
    # Escape single quotes in recommendation
    local safe_recommendation="${recommendation//\'/\'\\\'\'}"
    echo "RECOMMENDATION='${safe_recommendation:-}'"
    echo "COMPLETION_INDICATORS='${completion_indicators}'"
    echo "PR_CHUNK_COMPLETE='${pr_chunk_complete:-false}'"

    return 0
}

update_exit_signals() {
    local exit_signal="$1"
    local completion_indicators="$2"

    # Keep rolling window of last 5 signals
    local tmp
    tmp=$(mktemp)

    jq --arg sig "$exit_signal" \
       --argjson ind "$completion_indicators" \
       --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
       '. += [{"exit_signal": $sig, "completion_indicators": $ind, "timestamp": $ts}] | .[-5:]' \
       "$EXIT_SIGNALS_FILE" > "$tmp"
    mv "$tmp" "$EXIT_SIGNALS_FILE"
}

check_consecutive_exit_signals() {
    # Check for 2 consecutive true exit signals (from Ralph Claude Code)
    local consecutive
    consecutive=$(jq '[.[-2:][].exit_signal] | map(select(. == "true")) | length' "$EXIT_SIGNALS_FILE")

    if [[ "$consecutive" == "2" ]]; then
        return 0  # 2 consecutive exit signals
    fi
    return 1
}

should_exit() {
    local status="$1"
    local exit_signal="$2"
    local tasks_remaining="$3"
    local completion_indicators="$4"

    # ==========================================================================
    # Primary Exit Condition: <promise>COMPLETE</promise>
    # ==========================================================================
    # The simplest and most reliable signal - Claude outputs this tag when done
    if check_promise_complete "$RESPONSE_FILE"; then
        log INFO "Exit condition met: <promise>COMPLETE</promise> found"
        return 0
    fi

    # ==========================================================================
    # Dual-Condition Exit Gate (fallback)
    # ==========================================================================
    # Exit requires BOTH:
    # 1. EXIT_SIGNAL == "true" (explicit signal from Claude)
    # 2. At least ONE of:
    #    a. completion_indicators >= 2 (heuristic from natural language)
    #    b. STATUS == "COMPLETE"
    #    c. tasks_remaining == "0"
    #    d. 2 consecutive exit signals in history
    # ==========================================================================

    if [[ "$exit_signal" != "true" ]]; then
        log DEBUG "Exit check: EXIT_SIGNAL is not true, continuing"
        return 1
    fi

    # Exit signal is true, check secondary conditions
    if [[ "$status" == "COMPLETE" ]]; then
        log INFO "Exit condition met: STATUS=COMPLETE with EXIT_SIGNAL=true"
        return 0
    fi

    if [[ "$tasks_remaining" == "0" ]]; then
        log INFO "Exit condition met: TASKS_REMAINING=0 with EXIT_SIGNAL=true"
        return 0
    fi

    if (( completion_indicators >= 2 )); then
        log INFO "Exit condition met: $completion_indicators completion indicators with EXIT_SIGNAL=true"
        return 0
    fi

    if check_consecutive_exit_signals; then
        log INFO "Exit condition met: 2 consecutive EXIT_SIGNAL=true"
        return 0
    fi

    log WARN "EXIT_SIGNAL=true but no secondary condition met (status=$status, remaining=$tasks_remaining, indicators=$completion_indicators)"
    return 1
}

# =============================================================================
# Plan Completion Checking
# =============================================================================

check_plan_completion() {
    if [[ ! -f "$PLAN_FILE" ]]; then
        return 1  # No plan file, can't determine completion
    fi

    local total_tasks completed_tasks
    total_tasks=$(grep -c '^\s*- \[' "$PLAN_FILE" 2>/dev/null || echo "0")
    completed_tasks=$(grep -c '^\s*- \[x\]' "$PLAN_FILE" 2>/dev/null || echo "0")

    if [[ "$total_tasks" == "0" ]]; then
        return 1  # No tasks found
    fi

    if [[ "$total_tasks" == "$completed_tasks" ]]; then
        return 0  # All tasks completed
    fi

    return 1
}

# =============================================================================
# Main Loop
# =============================================================================

run_claude() {
    local iteration="$1"
    local start_time
    start_time=$(date +%s)

    # Read prompt file
    if [[ ! -f "$PROMPT_FILE" ]]; then
        die "Prompt file not found: $PROMPT_FILE"
    fi

    # Log files for this iteration (JSON for full data, plain text extracted for display)
    local iter_prefix="$LOG_DIR/iter_$(printf '%03d' "$iteration")_$(date '+%Y%m%d_%H%M%S')"
    local json_log_file="${iter_prefix}.json"
    local log_file="${iter_prefix}.log"

    log INFO "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log INFO "Iteration $iteration / $MAX_ITERATIONS"
    log INFO "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [[ "$DRY_RUN" == "true" ]]; then
        log INFO "[DRY RUN] Would execute: claude -p \"...\" --dangerously-skip-permissions"
        echo "STATUS=DRY_RUN"
        echo "EXIT_SIGNAL=false"
        echo "TASKS_REMAINING=unknown"
        echo "COMPLETION_INDICATORS=0"
        return 0
    fi

    # Build prompt with iteration context
    local full_prompt
    full_prompt=$(cat "$PROMPT_FILE")
    full_prompt+="

---
## Current Loop Context
- **Iteration:** $iteration / $MAX_ITERATIONS
- **Session:** $(get_state 'session_id')
- **Plan:** $PLAN_FILE
- **Working Directory:** $WORK_DIR

Please read $PLAN_FILE and proceed with the FIRST unchecked task.
Remember to output the RALPH_STATUS block at the end of your response.
"

    # Execute Claude Code with timeout
    local timeout_seconds=$(( TIMEOUT_MINUTES * 60 ))
    local exit_code=0

    log DEBUG "Executing Claude Code (timeout: ${TIMEOUT_MINUTES}m)..."

    # Run Claude in YOLO mode (--dangerously-skip-permissions) for autonomous operation
    # Output JSON to file for debugging/token tracking, also save to RESPONSE_FILE
    if timeout "$timeout_seconds" claude -p "$full_prompt" --model "$MODEL" --dangerously-skip-permissions --verbose --output-format stream-json 2>&1 | tee "$json_log_file" > "$RESPONSE_FILE"; then
        exit_code=0
    else
        exit_code=$?
        if [[ $exit_code -eq 124 ]]; then
            log WARN "Claude call timed out after $TIMEOUT_MINUTES minutes"
        fi
    fi

    # Extract plain text from JSON for readable log file
    if [[ -f "$json_log_file" ]]; then
        jq -r 'select(.type=="assistant" or .type=="user") | .message.content[]? | select(.type=="text") | .text' "$json_log_file" 2>/dev/null > "$log_file" || true
    fi

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    # Parse token usage and update metrics
    local token_usage input_tokens output_tokens
    token_usage=$(parse_token_usage "$RESPONSE_FILE")
    input_tokens=$(echo "$token_usage" | cut -d' ' -f1)
    output_tokens=$(echo "$token_usage" | cut -d' ' -f2)

    if [[ $exit_code -eq 0 ]]; then
        update_metrics "$input_tokens" "$output_tokens" "$duration" "true"
    else
        update_metrics "$input_tokens" "$output_tokens" "$duration" "false"
    fi

    # Parse response
    parse_ralph_status "$RESPONSE_FILE"

    return $exit_code
}

run_main_loop() {
    # Initialize state
    init_state_dir

    # Initialize PR chunk tracking
    init_pr_chunks

    # Check if resuming
    local current_iteration
    current_iteration=$(get_iteration)
    if (( current_iteration > 0 )); then
        log INFO "Resuming from iteration $current_iteration"
    fi

    # Banner
    echo -e "${GREEN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                     Ralph Loop - MVP                         ║"
    echo "║           Autonomous Claude Code Agent Loop                  ║"
    echo "║                     by Robert Sarosi                         ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    log INFO "Configuration:"
    log INFO "  Session:         $(get_state 'session_id')"
    log INFO "  Model:           $MODEL"
    log INFO "  Prompt file:     $PROMPT_FILE"
    log INFO "  Plan file:       $PLAN_FILE"
    log INFO "  Max iterations:  $MAX_ITERATIONS"
    log INFO "  Rate limit:      $RATE_LIMIT/hour"
    log INFO "  Timeout:         $TIMEOUT_MINUTES minutes"
    [[ -n "$WORKTREE_BRANCH" ]] && log INFO "  Worktree:        $WORKTREE_BRANCH"
    log INFO "  Working dir:     $WORK_DIR"
    echo ""

    # Main loop
    local iteration
    iteration=$(get_iteration)
    local consecutive_errors=0
    local max_consecutive_errors=3

    while (( iteration < MAX_ITERATIONS )); do
        iteration=$(( iteration + 1 ))
        set_iteration "$iteration"

        # Rate limit check
        if ! check_rate_limit; then
            log WARN "Waiting 60 seconds before retry..."
            sleep 60
            continue
        fi

        # Run Claude
        local parsed_output
        if parsed_output=$(run_claude "$iteration"); then
            consecutive_errors=0
        else
            consecutive_errors=$(( consecutive_errors + 1 ))
            log WARN "Iteration failed (consecutive errors: $consecutive_errors/$max_consecutive_errors)"

            if (( consecutive_errors >= max_consecutive_errors )); then
                set_state "status" '"failed"'
                die "Too many consecutive errors. Run --status to see progress, --reset to start over."
            fi

            log INFO "Waiting 30 seconds before retry..."
            sleep 30
            continue
        fi

        # Parse results
        local STATUS EXIT_SIGNAL TASKS_REMAINING TASKS_COMPLETED FILES_MODIFIED TESTS_STATUS WORK_TYPE RECOMMENDATION COMPLETION_INDICATORS PR_CHUNK_COMPLETE
        eval "$parsed_output"

        # Update exit signals history
        update_exit_signals "$EXIT_SIGNAL" "$COMPLETION_INDICATORS"

        # Log status
        log INFO "Status: $STATUS | Remaining: $TASKS_REMAINING | Exit: $EXIT_SIGNAL | Indicators: $COMPLETION_INDICATORS"
        [[ -n "${RECOMMENDATION:-}" ]] && log INFO "Recommendation: $RECOMMENDATION"

        # Check if PR chunk is complete
        check_and_notify_chunk_completion

        # Also check if Claude reported chunk completion
        if [[ -n "${PR_CHUNK_COMPLETE:-}" && "$PR_CHUNK_COMPLETE" != "false" ]]; then
            log INFO "Claude reported PR chunk complete: $PR_CHUNK_COMPLETE"
        fi

        # Show running cost
        local current_cost
        current_cost=$(jq '.estimated_cost_usd' "$METRICS_FILE")
        log INFO "Running cost: \$$current_cost"

        # Check exit conditions
        if should_exit "$STATUS" "$EXIT_SIGNAL" "$TASKS_REMAINING" "$COMPLETION_INDICATORS"; then
            set_state "status" '"completed"'

            echo ""
            echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${GREEN}✓ Task completed successfully!${NC}"
            echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo ""
            echo -e "${BOLD}Summary:${NC}"
            echo "  Iterations:    $iteration"
            echo "  Total tokens:  $(jq '.total_tokens' "$METRICS_FILE")"
            echo "  Total cost:    \$$(jq '.estimated_cost_usd' "$METRICS_FILE")"
            echo "  Duration:      $(jq '.total_duration_seconds' "$METRICS_FILE")s"
            [[ -n "$WORKTREE_BRANCH" ]] && echo "  Worktree:      $WORKTREE_BRANCH"
            echo ""
            echo "Full metrics: $METRICS_FILE"
            echo "Logs: $LOG_DIR/"
            exit 0
        fi

        # Also check fix_plan directly
        if check_plan_completion; then
            log INFO "All tasks in $PLAN_FILE are complete!"
            # Give one more iteration for Claude to confirm
        fi

        # Handle blocked status
        if [[ "$STATUS" == "BLOCKED" ]]; then
            log WARN "Claude reported BLOCKED status"
            log WARN "Recommendation: ${RECOMMENDATION:-Check progress.txt for details}"
            log INFO "Waiting 10 seconds before retry..."
            sleep 10
        fi

        # Brief pause between iterations
        sleep 2
    done

    # Max iterations reached
    set_state "status" '"max_iterations"'

    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}⚠ Max iterations ($MAX_ITERATIONS) reached${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${BOLD}Summary:${NC}"
    echo "  Iterations:    $iteration"
    echo "  Total tokens:  $(jq '.total_tokens' "$METRICS_FILE")"
    echo "  Total cost:    \$$(jq '.estimated_cost_usd' "$METRICS_FILE")"
    [[ -n "$WORKTREE_BRANCH" ]] && echo "  Worktree:      $WORKTREE_BRANCH"
    echo ""
    echo "Run ./ralph.sh -m $((MAX_ITERATIONS + 10)) to continue with more iterations"
    echo "Run ./ralph.sh --status to see detailed progress"
    exit 1
}

main() {
    # Parse arguments - first positional arg is the plan file
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage ;;
            -w|--worktree) WORKTREE_BRANCH="$2"; shift 2 ;;
            -b|--base) BASE_BRANCH="$2"; shift 2 ;;
            -m|--max-iterations) MAX_ITERATIONS="$2"; shift 2 ;;
            -r|--rate-limit) RATE_LIMIT="$2"; shift 2 ;;
            -p|--prompt) PROMPT_FILE="$2"; shift 2 ;;
            -t|--timeout) TIMEOUT_MINUTES="$2"; shift 2 ;;
            -M|--model) MODEL="$2"; shift 2 ;;
            -v|--verbose) VERBOSE=true; shift ;;
            --monitor) MONITOR_MODE=true; shift ;;
            --fresh) FRESH_START=true; shift ;;
            --dry-run) DRY_RUN=true; shift ;;
            --reset) init_state_paths; reset_state ;;
            --status) ensure_jq; show_status ;;
            -*)
                die "Unknown option: $1"
                ;;
            *)
                # First positional argument is the plan file
                if [[ -z "$PLAN_FILE" ]]; then
                    PLAN_FILE="$1"
                    shift
                else
                    die "Unexpected argument: $1"
                fi
                ;;
        esac
    done

    # Validate plan file is provided
    if [[ -z "$PLAN_FILE" ]]; then
        echo "Error: Plan file is required."
        echo ""
        echo "Usage: ./ralph.sh <plan.md> [options]"
        echo ""
        echo "Run ./ralph.sh --help for more information."
        exit 1
    fi

    # Validate dependencies
    ensure_jq
    command -v claude &>/dev/null || die "Claude Code CLI not found. Install from: https://docs.anthropic.com/claude-code"
    command -v bc &>/dev/null || die "bc is required but not installed. Install with: brew install bc"

    # Setup worktree if requested
    if [[ -n "$WORKTREE_BRANCH" ]]; then
        setup_worktree "$WORKTREE_BRANCH" "$BASE_BRANCH"
    fi

    # Initialize state paths (after potential worktree change)
    init_state_paths

    # Fresh start - reset state if requested
    if [[ "$FRESH_START" == "true" ]] && [[ -d "$STATE_DIR" ]]; then
        log WARN "Fresh start requested - resetting state..."
        rm -rf "$STATE_DIR"
    fi

    # Validate files (in current/worktree directory)
    [[ -f "$PROMPT_FILE" ]] || die "Prompt file not found: $PROMPT_FILE"
    [[ -f "$PLAN_FILE" ]] || die "Plan file not found: $PLAN_FILE"

    # Run in tmux if monitor mode requested
    if [[ "$MONITOR_MODE" == "true" ]]; then
        ensure_tmux
        run_in_tmux
        # run_in_tmux calls exec, so we never reach here
    fi

    # Run main loop
    run_main_loop
}

# =============================================================================
# Entry Point
# =============================================================================

main "$@"
