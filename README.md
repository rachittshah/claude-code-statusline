# Claude Code Status Line v2

Rich status line for Claude Code CLI — shows model, vim mode, agent, context, git, lines changed, cost, duration, and usage tracking.

## Preview

```
astroscore │ Opus │ N │ security-reviewer │ ██████░░░░ 55% │ main*3 │ +156-23 │ $0.01 │ 45s │ ███████░ 88% 5x │ r:2h15m
```

| Segment | Source Field | Description |
|---------|-------------|-------------|
| `astroscore` | `workspace.current_dir` | Current directory (basename) |
| `Opus` | `model.display_name` | Active model |
| `N` | `vim.mode` | Vim mode (N/I/V/R) |
| `security-reviewer` | `agent.name` | Active agent name |
| `██████░░░░ 55%` | `context_window.used_percentage` | Context window usage |
| `!` | `exceeds_200k_tokens` | Context overflow warning |
| `main*3` | git status | Branch + dirty file count |
| `+156-23` | `cost.total_lines_added/removed` | Lines changed this session |
| `$0.01` | `cost.total_cost_usd` | Session cost |
| `45s` | `cost.total_duration_ms` | Session duration |
| `███████░ 88% 5x` | usage-detector | 5-hour usage % + plan badge |
| `r:2h15m` | usage-detector | Time until limit reset |

Segments are hidden when their data is empty (no vim mode = no vim segment, etc.).

## Installation

### Prerequisites

- `jq` (required)
- `bun` (optional, for usage tracking via [ccusage](https://github.com/ryoppippi/ccusage))

### Quick Install

```bash
git clone https://github.com/rachittshah/claude-code-statusline.git
cd claude-code-statusline
bash install.sh
```

### Manual Install

```bash
# macOS
brew install jq

# Linux (Debian/Ubuntu)
sudo apt-get install -y jq

# Copy scripts
mkdir -p ~/.claude/statusline
cp statusline.sh usage-detector.sh usage-bar.sh ~/.claude/statusline/
chmod +x ~/.claude/statusline/*.sh
```

Add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "$HOME/.claude/statusline/statusline.sh"
  }
}
```

## Features

- **Native JSON fields** — Uses `cost.total_cost_usd`, `context_window.used_percentage`, `vim.mode`, `agent.name`, etc.
- **Single jq call** — All fields extracted in one pass (4x faster than v1)
- **Cross-platform** — Works on macOS and Linux
- **Backward compatible** — Falls back to token-based context calculation when `used_percentage` is unavailable
- **Auto-detects plan** — Pro, Max 5x, Max 20x, or API (via credential metadata)
- **3 usage detection methods** — Anthropic API, prompt estimation, cost-based
- **Context overflow warning** — Shows `!` when `exceeds_200k_tokens` is true

## JSON Schema Reference

<details>
<summary>Full input JSON schema (click to expand)</summary>

```json
{
  "hook_event_name": "Status",
  "model": {
    "display_name": "Opus"
  },
  "workspace": {
    "current_dir": "/home/user/project"
  },
  "context_window": {
    "used_percentage": 55,
    "context_window_size": 200000,
    "current_usage": {
      "input_tokens": 50000,
      "cache_creation_input_tokens": 10000,
      "cache_read_input_tokens": 5000
    }
  },
  "cost": {
    "total_cost_usd": 0.01234,
    "total_duration_ms": 45000,
    "total_lines_added": 156,
    "total_lines_removed": 23
  },
  "exceeds_200k_tokens": false,
  "vim": {
    "mode": "NORMAL"
  },
  "agent": {
    "name": "security-reviewer"
  }
}
```

</details>

## Usage Tracking

### Plan Auto-Detection

The detector identifies your plan from credential metadata:

1. **API key**: `ANTHROPIC_API_KEY` set — API mode (no usage tracking)
2. **Credential metadata**: Reads `subscriptionType`/`rateLimitTier` from:
   - macOS: Keychain (`Claude Code-credentials`)
   - Linux: `~/.claude/.credentials.json`
3. **Cost inference**: Falls back to historical cost (via ccusage)

Override manually:

```bash
export CLAUDE_PLAN=max20  # pro, max5, max20, api
```

### Plan Limits

| Plan | Prompts/5hr | Cost Limit |
|------|-------------|------------|
| Pro | 10-40 | ~$10 |
| Max 5x | 50-200 | ~$50 |
| Max 20x | 200-800 | ~$200 |

### Standalone Usage

```bash
~/.claude/statusline/usage-detector.sh json | jq .
```

## Files

| File | Description |
|------|-------------|
| `statusline.sh` | Main status line (reads Claude Code JSON from stdin) |
| `usage-detector.sh` | Usage detection engine (3 methods, cross-platform) |
| `usage-bar.sh` | Standalone usage bar (for terminal prompts) |
| `install.sh` | Cross-platform installer |

## Credits

- [ccusage](https://github.com/ryoppippi/ccusage) — Usage analysis from local conversation files
- [Claude Code Docs](https://docs.anthropic.com/en/docs/claude-code) — Status line configuration

## License

MIT
