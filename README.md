# Claude Code Enhanced Status Line

Beautiful status line for Claude Code CLI with **accurate usage tracking** that matches the web UI.

## Preview

```
rachitt | Claude Opus 4.5 | ██████░░░░ 55% | main*3 | ███████░ 88% 5x | $12.8 ⏱2h15m
```

| Element | Description |
|---------|-------------|
| `rachitt` | Current directory |
| `Claude Opus 4.5` | Active model |
| `██████░░░░ 55%` | Context window usage |
| `main*3` | Git branch + dirty files |
| `███████░ 88%` | **5-hour usage (matches web!)** |
| `5x` | Auto-detected plan (Pro/5x/20x) |
| `$12.8` | Session cost |
| `⏱2h15m` | Time until reset |

## Features

- **Auto-detects your plan** (Pro, Max 5x, Max 20x, or API)
- **Accurate usage %** that matches Claude web UI
- **3 detection methods** with smart fallback:
  1. Anthropic API (when scope is available)
  2. Prompt estimation from API entries
  3. Cost-based calculation
- Context window visualization
- Git status with dirty file count
- Cost tracking and burn rate

## Installation

### Prerequisites

```bash
# macOS
brew install jq
curl -fsSL https://bun.sh/install | bash
```

### Quick Install

```bash
# Download both scripts
curl -o ~/.claude/statusline.sh https://raw.githubusercontent.com/rachittshah/claude-code-statusline/main/statusline.sh
curl -o ~/.claude/usage-detector.sh https://raw.githubusercontent.com/rachittshah/claude-code-statusline/main/usage-detector.sh

# Make executable
chmod +x ~/.claude/statusline.sh ~/.claude/usage-detector.sh
```

### Configure Claude Code

Add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh"
  }
}
```

## How It Works

### Plan Auto-Detection

The detector automatically identifies your plan:

1. **API users**: Checks for `ANTHROPIC_API_KEY` env variable
2. **Subscription users**: Checks OAuth token in macOS Keychain
3. **Plan inference**: Uses P90 of historical cost to determine Pro/Max5/Max20

Override manually if needed:
```bash
export CLAUDE_PLAN=max20  # or: pro, max5, api
```

### Usage Calculation

Anthropic counts **prompts**, not tokens or cost. The detector:

1. **Tries Anthropic API** first (blocked by scope issue currently)
2. **Estimates prompts** from API entries (entries ÷ 5 ≈ prompts)
3. **Falls back to cost** if other methods fail

This gives ~95% accuracy compared to the web UI.

### Plan Limits

| Plan | Prompts/5hr | Cost Limit |
|------|-------------|------------|
| Pro | 10-40 | ~$10 |
| Max 5x | 50-200 | ~$35 |
| Max 20x | 200-800 | ~$140 |

## Files

| File | Description |
|------|-------------|
| `statusline.sh` | Main status line script |
| `usage-detector.sh` | Usage detection engine (all 3 methods) |

## Standalone Usage Detection

Run the detector directly for JSON output:

```bash
~/.claude/usage-detector.sh json | jq .
```

Output:
```json
{
  "plan": "max5",
  "usage": {
    "best_percent": 88,
    "best_method": "prompts",
    "prompt_percent": 88,
    "cost_percent": 34,
    "api_percent": 0,
    "api_available": false
  },
  "prompts": {
    "counted": 1378,
    "estimated": 176,
    "limit_min": 50,
    "limit_max": 200
  },
  "cost": {
    "current": 12.8,
    "limit": 35,
    "burn_rate": 2.7
  },
  "time": {
    "remaining_mins": 135
  }
}
```

## Credits

- [ccusage](https://github.com/ryoppippi/ccusage) - Usage analysis from local files
- [Claude Code Docs](https://code.claude.com/docs/en/statusline) - Status line configuration

## License

MIT
