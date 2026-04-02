# claude-code-statusline

A status bar for Claude Code that tells you not just where you are, but whether you need to act.

```
S ████████▍─ 73% ↻1h08m 12%/h │ W █████████▊ 92% ↻Mon 5pm │ Ctx 45%↑ │ $2.71 │ opus-4.6 H │ ⚡Peak │ main*2
```

## Install

```bash
git clone https://github.com/rachittshah/claude-code-statusline ~/.claude-statusline
cd ~/.claude-statusline && bash install.sh
```

Restart Claude Code. Done.

## What it shows

| Widget | What you see | What it means |
|--------|-------------|---------------|
| **Session** | `S ████████▍─ 73% ↻1h08m` | 5-hour usage at 73%, resets in 1h08m |
| **Burn rate** | `12%/h` | Burning 12% per hour at current pace |
| **Runway alert** | `⚠~45m` | You'll hit the limit before it resets. Slow down. |
| **Weekly** | `W █████████▊ 92% ↻Mon 5pm` | 7-day usage at 92%, resets Monday 5pm |
| **Context** | `Ctx 45%↑` | Context window 45% full, growing (↑↑↑ = fast) |
| **Cost** | `$2.71` | Session cost in your currency |
| **Model** | `opus-4.6 H` | Current model + effort level (H/M/L) |
| **Peak** | `⚡Peak` | Anthropic's 2x consumption window is active |
| **Git** | `main*2` | Branch with 2 dirty files |

The runway alert only appears when you're on track to hit rate limits before they reset. No alert = you're fine.

## Features

- **Burn rate + runway prediction** — Linear regression over your usage history predicts when you'll hit limits. The bar warns you before it happens.
- **Context velocity** — Arrows (↑/↑↑/↑↑↑) show how fast your context window is filling up.
- **Peak hours** — Warns when Anthropic's 2x consumption window is active.
- **One color palette** — Traffic-light gradient (green → amber → red). No theme bloat.
- **Smart layout** — Adapts to terminal width. Drops low-priority widgets to fit.
- **Zero dependencies** — Pure Python stdlib. No pip, no npm, no cargo.
- **Sub-50ms** — Aggressive caching on git status and FX rates. Hot path is <10ms.
- **Currency conversion** — Live exchange rates, cached 24h. 17 currencies supported.
- **Never crashes** — Graceful fallback on any error. Always shows something.

## Configure

```bash
python3 ~/.claude-statusline/statusline.py --config           # Show settings
python3 ~/.claude-statusline/statusline.py --demo             # Preview the bar
python3 ~/.claude-statusline/statusline.py --currency £        # Set currency
python3 ~/.claude-statusline/statusline.py --bar-width large   # Bar width (small/medium/large/xl or 4-20)
python3 ~/.claude-statusline/statusline.py --show burn_rate    # Enable a widget
python3 ~/.claude-statusline/statusline.py --hide peak         # Disable a widget
python3 ~/.claude-statusline/statusline.py --peak-hours 13:00-19:00  # Set peak window
python3 ~/.claude-statusline/statusline.py --reset             # Factory reset
```

### Widgets you can show/hide

`session` · `weekly` · `context` · `cost` · `model` · `git` · `effort` · `peak` · `burn_rate` · `runway_alert` · `reset_timer` · `context_velocity`

## How it works

Claude Code pipes JSON to stdin on each interaction. This script parses it, computes derived metrics (burn rate via linear regression, context velocity, runway prediction), and outputs an ANSI-colored status line. No API calls, no token consumption — everything runs locally.

Usage data comes from Claude Code's native `rate_limits` field (available since v2.1.80). No OAuth tokens, no credential scraping, no third-party tools.

## Requirements

- Python 3.8+
- Claude Code (any recent version; rate limit bars require v2.1.80+)

## License

MIT
