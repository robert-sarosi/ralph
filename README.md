# Ralph

An autonomous coding agent loop that repeatedly calls Claude Code until tasks are complete.

## Quick Start

```bash
# Basic usage
./ralph.sh plan.md

# With git worktree for isolated feature work
./ralph.sh plan.md -w feature/my-feature

# With tmux monitoring UI
./ralph.sh plan.md --monitor
```

## How It Works

1. **Create a plan** - In an interactive session with a smart model (Claude, etc.), create a detailed plan or PRD for your feature
2. **Convert to ralph format** - Use `ralph-format-plan.sh` to convert your plan into ralph's checkbox format
3. **Run ralph** - Execute `./ralph.sh plan.md` to start the autonomous loop
4. **Monitor and adjust** - Check what ralph is doing:
   - If it's implementing in the right direction, let it work
   - If not, update `PROMPT.md` or create a `.claude/agents.md` with proper guidance and rules
5. Ralph calls Claude Code in a loop, each iteration working on the first unchecked task
6. Claude marks tasks complete and reports status via `RALPH_STATUS` blocks
7. Loop exits when all tasks are done or max iterations reached

## Files

| File | Purpose |
|------|---------|
| `ralph.sh` | Main loop script |
| `PROMPT.md` | Instructions sent to Claude each iteration |
| `PRD-TEMPLATE.md` | User story format for plan files |
| `TASKS-TEMPLATE.md` | Technical task format for plan files |
| `ralph-format-plan.sh` | Helper to generate plan files |

## Options

```
-w, --worktree BRANCH   Create git worktree for isolated work
-m, --max-iterations N  Max iterations (default: 10)
-t, --timeout MIN       Timeout per call in minutes (default: 15)
--monitor               Run in tmux with live status panes
--status                Show current progress
--reset                 Clear state and start fresh
```

## State

Ralph persists state in `.ralph/`:
- `state.json` - Session info, iteration count
- `metrics.json` - Token usage and cost tracking
- `logs/` - Per-iteration logs

## Requirements

- Claude Code CLI (`claude`)
- `jq`, `bc`
- `tmux` (for `--monitor` mode)
