#!/bin/bash
# ralph-format-plan.sh - LLM-powered plan formatter for Ralph
# Usage: ralph-format-plan.sh [--prd|--tasks] [-o output] <input-files...>

set -e

# Parse flags
FORMAT=""
OUTPUT_FILE=""
INPUT_FILES=()

while [[ $# -gt 0 ]]; do
    case $1 in
        --prd)
            FORMAT="prd"
            shift
            ;;
        --tasks)
            FORMAT="tasks"
            shift
            ;;
        -o|--output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -h|--help)
            # Will call usage() after it's defined
            SHOW_HELP=true
            shift
            ;;
        *)
            INPUT_FILES+=("$1")
            shift
            ;;
    esac
done

# Set default output based on format (if specified and not already set)
if [[ -z "$OUTPUT_FILE" ]]; then
    if [[ "$FORMAT" == "prd" ]]; then
        OUTPUT_FILE="PRD.md"
    elif [[ "$FORMAT" == "tasks" ]]; then
        OUTPUT_FILE="TASKS.md"
    fi
    # If format not specified, OUTPUT_FILE will be set after auto-detection
fi

usage() {
    cat << 'EOF'
ralph-format-plan - Convert plans to Ralph format using LLM

USAGE:
    ralph-format-plan.sh [OPTIONS] <input-files...>
    ralph-format-plan.sh [OPTIONS] -o output.md file1.md file2.md ...
    cat plan.md | ralph-format-plan.sh [OPTIONS] -
    pbpaste | ralph-format-plan.sh --prd -

OPTIONS:
    --prd           Output PRD format (user stories, non-technical)
    --tasks         Output Tasks format (technical implementation details)
    -o, --output    Output file path (default: PRD.md or TASKS.md based on format)
    (no flag)       Auto-detect format based on input content

ARGUMENTS:
    input-files     One or more input files (use - for stdin)
                    Multiple files are concatenated in order

FORMAT DIFFERENCES:
    PRD (User Stories):
      - "As a [user], I want [X] so that [Y]"
      - No technical implementation details
      - Focus on user value and behavior
      - Best for: feature requests, user requirements

    Tasks (Technical):
      - Specific files, functions, patterns to modify
      - Implementation guidance per task
      - Technical acceptance criteria
      - Best for: technical specs, architecture decisions, bug fixes

SIZING CONSTRAINTS:
    Each story/task must be:
    - Completable in ONE iteration (~100K tokens)
    - Describable in 2-3 sentences
    - Touching 1-5 files maximum

EXAMPLES:
    # Single file (auto-detect format)
    ralph-format-plan.sh feature-request.md

    # Multiple files combined into one plan
    ralph-format-plan.sh --tasks spec.md plan.md -o TASKS.md

    # Combine spec and implementation plan
    ralph-format-plan.sh --tasks specs/spec.md specs/plan.md

    # Force PRD format
    ralph-format-plan.sh --prd user-requirements.md

    # From stdin
    pbpaste | ralph-format-plan.sh -
    cat spec.md plan.md | ralph-format-plan.sh --tasks -

See PRD-TEMPLATE.md and TASKS-TEMPLATE.md for format references.
EOF
    exit 1
}

[[ "$SHOW_HELP" == true ]] && usage
[[ ${#INPUT_FILES[@]} -eq 0 ]] && usage

echo "" >&2
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
echo "🚀 ralph-format-plan" >&2
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2

# Read input from one or more files
echo "📄 Reading input..." >&2
INPUT_CONTENT=""

for INPUT_FILE in "${INPUT_FILES[@]}"; do
    if [[ "$INPUT_FILE" == "-" ]]; then
        STDIN_CONTENT=$(cat)
        INPUT_CONTENT+="$STDIN_CONTENT"
        echo "   Read from stdin ($(echo "$STDIN_CONTENT" | wc -c | tr -d ' ') bytes)" >&2
    else
        [[ ! -f "$INPUT_FILE" ]] && echo "Error: File not found: $INPUT_FILE" >&2 && exit 1
        FILE_CONTENT=$(cat "$INPUT_FILE")
        INPUT_CONTENT+="$FILE_CONTENT"
        INPUT_CONTENT+=$'\n\n'  # Add separator between files
        echo "   Read from: $INPUT_FILE ($(echo "$FILE_CONTENT" | wc -c | tr -d ' ') bytes)" >&2
    fi
done

echo "   Total input: $(echo "$INPUT_CONTENT" | wc -c | tr -d ' ') bytes from ${#INPUT_FILES[@]} file(s)" >&2

# Check for claude CLI
echo "🔍 Checking for claude CLI..." >&2
if ! command -v claude &> /dev/null; then
    echo "Error: claude CLI not found. Install from https://claude.ai/code" >&2
    exit 1
fi
echo "   ✓ claude CLI found" >&2

# Spinner function for long-running commands
spinner() {
    local pid=$1
    local msg=$2
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    local elapsed=0

    while kill -0 "$pid" 2>/dev/null; do
        printf "\r   %s %s (%ds)..." "${spin:i++%10:1}" "$msg" "$elapsed" >&2
        sleep 1
        ((elapsed++))
    done
    printf "\r   ✓ %s (%ds)          \n" "$msg" "$elapsed" >&2
}

# Common constraints for both formats
COMMON_CONSTRAINTS='CONSTRAINTS PER STORY/TASK:
- Must complete in ONE Ralph iteration (~100K tokens of work)
- Describable in 2-3 sentences (if longer, split it)
- Has 2-5 acceptance criteria
- Touches 1-5 files maximum
- < 15 min human review time

PHASE/STORY ORDER (by dependency):
1. Schema/Types (data models, interfaces, DB migrations)
2. Backend (API endpoints, services, business logic)
3. Frontend (UI components, pages, forms)
4. Integration (connecting pieces, hooks, wiring)
5. Testing (minimal ~20% effort, only for NEW test creation)
6. Documentation (only if explicitly requested)

ACCEPTANCE CRITERIA RULES:
- Every story/task MUST have 2-5 acceptance criteria
- Each criterion MUST be objectively verifiable:
  * Can run a test to verify
  * Can check file/endpoint exists
  * Can observe specific behavior
- Use concrete terms: "returns 200", "file exists at X", "renders Y component"
- AVOID vague criteria: "works correctly", "is implemented", "handles errors"

IMPLICIT GLOBAL CRITERIA (do NOT list these, always enforced):
- Build passes (typecheck, lint, compile)
- All tests pass (unit, integration)
- Code review agents report no major/critical issues (quality, security, performance)

RULES:
- Break large features into smaller atomic pieces
- Order by dependency (what must exist before the next can be built)
- Use imperative verbs: "Add", "Create", "Update", "Fix", "Remove"
- Skip testing/documentation unless explicitly requested'

PRD_PROMPT='You are a PRD specialist for the Ralph autonomous coding agent.

Your job: Convert input into a PRD with user stories (non-technical, user-focused).

'"$COMMON_CONSTRAINTS"'

OUTPUT FORMAT:
```
# PRD: [Feature Name]

## Project: [Project Name]
**Branch:** ralph/[feature-name]
**Status:** IN_PROGRESS

## Description
[2-3 sentence feature description from user perspective]

---

## User Stories

### US-001: [Title]
**Priority:** 1
**Status:** [ ] pending

As a [user type], I want [goal] so that [benefit].

**Acceptance Criteria:**
- [ ] Specific, verifiable user-facing criterion
- [ ] Another criterion with observable behavior
- [ ] Testable condition from user perspective

---

### US-002: [Title]
**Priority:** 2
**Status:** [ ] pending

As a [user type], I want [goal] so that [benefit].

**Acceptance Criteria:**
- [ ] User-facing criterion
- [ ] Observable behavior

---

## Completion

Feature complete when:
- All stories have [x] complete status
- All acceptance criteria checked
- Tests passing
- Code review agents report no major issues
```

PR BOUNDARY GUIDELINES:
For plans with 5+ user stories, insert PR markers between logical groupings that could be reviewed independently:

1. After core/setup stories
2. Between major feature areas
3. Before polish/edge-case stories

Use this marker format (between stories, after the --- separator):
<!-- PR: descriptive-name -->

Example names: "core-feature", "feature-ui", "feature-polish"

IMPORTANT: Do NOT include technical implementation details (specific files, code patterns, functions).
Focus on WHAT the user can do, not HOW it is implemented.

CRITICAL: Output ONLY the formatted PRD. Do NOT ask questions, request clarification, or add commentary. Just output the PRD markdown directly.'

TASKS_PROMPT='You are a technical task breakdown specialist for the Ralph autonomous coding agent.

Your job: Convert input into technical implementation tasks with specific guidance.

'"$COMMON_CONSTRAINTS"'

OUTPUT FORMAT:
```
# Tasks: [Feature Name]

## Overview
[Brief technical summary]

---

## Phase 1: Schema & Types

### T-001: [Task Title]
**Status:** [ ] pending

[1-2 sentence technical description]

**Implementation:**
- File: `path/to/file.ts`
- [Specific changes: add function X, modify class Y, etc.]
- [Pattern to follow or reference]

**Acceptance Criteria:**
- [ ] Specific technical criterion (e.g., "Interface exported from index.ts")
- [ ] Verifiable state (e.g., "GET /api/x returns 200")
- [ ] Code quality criterion (e.g., "No TypeScript errors")

---

## Phase 2: Backend

### T-002: [Task Title]
**Status:** [ ] pending

[1-2 sentence technical description]

**Implementation:**
- File: `path/to/file.ts`
- [Specific implementation guidance]

**Acceptance Criteria:**
- [ ] Technical criterion
- [ ] Verifiable outcome

---

## Completion

Feature complete when:
- All tasks have [x] complete status
- All acceptance criteria checked
- Tests passing
- Code review agents report no major issues
```

PR BOUNDARY GUIDELINES:
For plans with 5+ tasks, insert PR markers between logical groupings of tasks that could be reviewed independently:

1. After infrastructure/setup phase (schema, types, config)
2. Between major feature areas
3. Before testing/documentation phase
4. When a complete vertical slice is done (backend + frontend for one feature)

Use this marker format (between tasks, after the --- separator):
<!-- PR: descriptive-name -->

Example names: "auth-infrastructure", "auth-api", "auth-ui", "auth-tests"

IMPORTANT: Include specific technical details:
- File paths to create/modify
- Function/class/interface names
- Patterns to follow
- Dependencies to use

CRITICAL: Output ONLY the formatted Tasks document. Do NOT ask questions, request clarification, summarize, or add commentary. Just output the Tasks markdown directly.'

AUTO_DETECT_PROMPT='You are a format classifier for the Ralph autonomous coding agent.

Analyze the input and determine the best output format:

PRD FORMAT (user stories) - Use when input:
- Describes features from user perspective
- Uses non-technical language
- Focuses on "what" users can do
- Contains requirements like "users should be able to..."
- Is a feature request or user requirement

TASKS FORMAT (technical) - Use when input:
- Contains technical specifications
- Mentions specific files, APIs, or code
- Describes implementation details
- Contains architecture decisions
- Is a bug fix or technical improvement
- References specific technologies or patterns

Respond with ONLY one word: PRD or TASKS'

# Auto-detect format if not specified
if [[ -z "$FORMAT" ]]; then
    echo "" >&2
    echo "🤖 Auto-detecting format..." >&2

    # Run auto-detect in background with spinner
    DETECT_TEMP=$(mktemp)
    (echo "$INPUT_CONTENT" | claude -p "$AUTO_DETECT_PROMPT

Classify this input:

$INPUT_CONTENT" > "$DETECT_TEMP") &
    DETECT_PID=$!

    spinner $DETECT_PID "Analyzing content"

    wait $DETECT_PID
    FORMAT=$(cat "$DETECT_TEMP" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    rm -f "$DETECT_TEMP"

    # Validate response
    if [[ "$FORMAT" != "prd" && "$FORMAT" != "tasks" ]]; then
        echo "   ⚠️  Auto-detection unclear, defaulting to PRD" >&2
        FORMAT="prd"
    else
        echo "   → Detected: $FORMAT" >&2
    fi

    # Set default output file if not specified
    if [[ -z "$OUTPUT_FILE" ]]; then
        if [[ "$FORMAT" == "prd" ]]; then
            OUTPUT_FILE="PRD.md"
        else
            OUTPUT_FILE="TASKS.md"
        fi
    fi
else
    echo "" >&2
    echo "📋 Using specified format: $FORMAT" >&2
fi

# Select prompt based on format
if [[ "$FORMAT" == "prd" ]]; then
    ACTIVE_PROMPT="$PRD_PROMPT"
    CONVERT_MSG="Convert this to PRD format with user stories. Output ONLY the markdown, nothing else:"
    FORMAT_DESC="PRD (user stories)"
else
    ACTIVE_PROMPT="$TASKS_PROMPT"
    CONVERT_MSG="Convert this to Tasks format with technical implementation details. Output ONLY the markdown, nothing else:"
    FORMAT_DESC="Tasks (technical)"
fi

# Run through Claude
echo "" >&2
echo "⚙️  Converting to $FORMAT_DESC format..." >&2

# Create temp file for output
TEMP_OUTPUT=$(mktemp)
trap "rm -f $TEMP_OUTPUT" EXIT

# Run claude in background and show spinner
(echo "$INPUT_CONTENT" | claude -p "$ACTIVE_PROMPT

$CONVERT_MSG

$INPUT_CONTENT" > "$TEMP_OUTPUT") &
CLAUDE_PID=$!

spinner $CLAUDE_PID "Processing with Claude"

# Check if claude succeeded
wait $CLAUDE_PID
CLAUDE_EXIT=$?
if [[ $CLAUDE_EXIT -ne 0 ]]; then
    echo "   ❌ Claude command failed (exit code: $CLAUDE_EXIT)" >&2
    exit 1
fi

RESULT=$(cat "$TEMP_OUTPUT")

# Check if result looks like a question/clarification instead of formatted output
if [[ -z "$RESULT" ]]; then
    echo "   ❌ Error: Claude returned empty output" >&2
    exit 1
fi

# Check if Claude asked a question instead of outputting
if [[ ! "$RESULT" =~ ^#.*Tasks:|^#.*PRD: ]] && [[ "$RESULT" =~ "Would you like" || "$RESULT" =~ "Do you want" || "$RESULT" =~ "?" ]]; then
    echo "" >&2
    echo "⚠️  Warning: Claude may have asked a question instead of formatting." >&2
    echo "   First 200 chars of response:" >&2
    echo "   ${RESULT:0:200}..." >&2
    echo "" >&2
    echo "   Try running with --prd or --tasks flag to force format." >&2
fi

# Write output
echo "" >&2
echo "💾 Writing output..." >&2
if [[ "$OUTPUT_FILE" == "-" ]]; then
    echo "   Output to stdout" >&2
    echo "" >&2
    echo "$RESULT"
else
    echo "$RESULT" > "$OUTPUT_FILE"
    echo "" >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    echo "✅ Complete!" >&2
    echo "" >&2

    # Count items (use head -1 to ensure single line)
    if [[ "$FORMAT" == "prd" ]]; then
        count=$(grep -c '^### US-' "$OUTPUT_FILE" 2>/dev/null | head -1 || echo "0")
        [[ -z "$count" ]] && count=0
        echo "   📄 Output:     $OUTPUT_FILE" >&2
        echo "   📋 Format:     PRD (user stories)" >&2
        echo "   📝 Stories:    $count" >&2
    else
        count=$(grep -c '^### T-' "$OUTPUT_FILE" 2>/dev/null | head -1 || echo "0")
        [[ -z "$count" ]] && count=0
        echo "   📄 Output:     $OUTPUT_FILE" >&2
        echo "   📋 Format:     Tasks (technical)" >&2
        echo "   📝 Tasks:      $count" >&2
    fi
    echo "   🔄 Est. iterations: $count" >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2

    # Warn if no items found
    if [[ "$count" -eq 0 ]]; then
        echo "" >&2
        echo "⚠️  Warning: No tasks/stories detected in output!" >&2
        echo "   This may indicate Claude's response didn't match expected format." >&2
        echo "   Check $OUTPUT_FILE to see what was generated." >&2
    fi
fi
