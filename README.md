# Claude Code Enhanced Status Line

Beautiful status line for Claude Code CLI with usage tracking, context visualization, and git status.

![Status Line Example](https://img.shields.io/badge/Claude%20Code-Status%20Line-blue)

## Preview

```
myproject | Claude Opus 4.5 | ctx:████░░░░░░░░ 35% | main 3f +45 -12 | ██████░░ 67% $23.50 (2h15m @$1.58/h)
```

| Element | Description |
|---------|-------------|
| `myproject` | Current directory |
| `Claude Opus 4.5` | Active model |
| `ctx:████░░░░` 35% | Context window usage |
| `main 3f +45 -12` | Git branch, files changed, lines +/- |
| `██████░░` 67% | 5-hour block usage (cost-based) |
| `$23.50` | Current block cost |
| `(2h15m @$1.58/h)` | Time left in block + burn rate |

## Installation

### Prerequisites

- [jq](https://stedolan.github.io/jq/) - JSON processor
- [bun](https://bun.sh/) or npm - for ccusage

```bash
# macOS
brew install jq
curl -fsSL https://bun.sh/install | bash
```

### Quick Install

```bash
# Download the script
curl -o ~/.claude/statusline.sh https://raw.githubusercontent.com/rachittshah/claude-code-statusline/main/statusline.sh

# Make executable
chmod +x ~/.claude/statusline.sh
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

## Configuration

Set your Max plan limit in your shell profile (`~/.zshrc` or `~/.bashrc`):

```bash
# Max 5x plan (~$35 per 5hr block)
export CLAUDE_BLOCK_LIMIT=35

# Max 20x plan (~$140 per 5hr block)
export CLAUDE_BLOCK_LIMIT=140

# Pro plan (~$10 per 5hr block)
export CLAUDE_BLOCK_LIMIT=10
```

## How It Works

### Context Window Tracking
Reads JSON from Claude Code's status line API which includes:
- `context_window.context_window_size` - Total context size
- `context_window.current_usage` - Current token usage

### Usage Tracking
Uses [ccusage](https://github.com/ryoppippi/ccusage) to analyze local JSONL files in `~/.claude/projects/`:
- Tracks 5-hour billing blocks
- Calculates cost and burn rate
- Projects remaining time

> **Note:** Direct API access to usage limits requires `user:profile` OAuth scope which is a [known issue](https://github.com/anthropics/claude-code/issues/13724). This script uses local file analysis instead.

## Files

- `statusline.sh` - Full-featured status line with all components
- `usage-bar.sh` - Standalone usage tracking (can be run independently)

## Credits

- [ccusage](https://github.com/ryoppippi/ccusage) - Usage analysis from local files
- [Claude Code Docs](https://code.claude.com/docs/en/statusline) - Status line configuration

## License

MIT
