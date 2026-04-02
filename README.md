# claude-code-statusline

A decision-engine status bar for Claude Code. Not a dashboard — a control panel that tells you when to act.

```
C █▍──────── 14% │ $14.30 │ opus 4.6 │ +987 -226 │ ⚡43 tools 9/m │ 42m │ ⚡Peak │ 12H 5P 11A 18S │ main*2
```

## Install

```bash
git clone https://github.com/rachittshah/claude-code-statusline ~/.claude-statusline
cd ~/.claude-statusline && bash install.sh
```

Then install the analytics hooks (session journal + live telemetry):

```bash
~/.claude-statusline/statusline.py --install-hooks
```

Restart Claude Code. Done.

## What you see

| Widget | Example | What it means |
|--------|---------|---------------|
| **Context** | `C █▍──────── 14%` | Context window 14% full. Truecolor gradient bar: green → amber → red |
| **Context velocity** | `↑↑` | Context is growing fast. `↑` = slow, `↑↑` = moderate, `↑↑↑` = rapid |
| **Cost** | `$14.30` | Session cost. Supports 17 currencies with live FX conversion |
| **Model** | `opus 4.6 H` | Current model + effort level (H/M/L) |
| **Lines** | `+987 -226` | Lines added (green) and removed (red) this session |
| **Telemetry** | `⚡43 tools 9/m` | Live tool counter + velocity from PostToolUse hook |
| **Duration** | `42m` | Session duration |
| **Peak** | `⚡Peak` | Anthropic's 2x consumption window is active |
| **Harness** | `12H 5P 11A 18S` | Hooks, Plugins, Agents, Skills — your full setup at a glance |
| **Git** | `main*2` | Branch + dirty file count |
| **Session bar** | `S ████████▍─ 73% ↻1h08m` | 5-hour usage (Max plans). With burn rate and runway alert |
| **Weekly bar** | `W █████████▊ 92% ↻Mon` | 7-day usage (Max plans). With reset countdown |
| **Runway alert** | `⚠~45m` | You'll hit rate limits before they reset. Only appears when you need to slow down |
| **Burn rate** | `12%/h` | Usage rate via linear regression over 30 min of history |

Works on both **Max** (session + weekly bars) and **Enterprise** (context + cost + telemetry) plans.

## Session Analytics

Every session is recorded to a local journal. View your analytics:

```bash
~/.claude-statusline/statusline.py --stats
```

```
claude-statusline — session analytics

  Today        3 sessions     $42.71      +4.2K lines     2.1h     289 tools
  This week   14 sessions    $187.30     +18.9K lines     9.4h    1247 tools
  All time    89 sessions   $1,247.00    +127K lines       62h    8901 tools

  Cost by repo
    GOIBench           ████████████████████   12 sessions    $62.40     +8.2K    1204 tools
    evals              ███████████▌────────    8 sessions    $48.10     +5.1K     892 tools
    helion-thesis      ██████──────────────    6 sessions    $31.20     +3.8K     601 tools

  Cost/line: $0.010 │ Avg session: 38m │ Avg tools: 100/session │ Tools/line: 0.07
```

## System Status

See your full Claude Code harness:

```bash
~/.claude-statusline/statusline.py --status
```

Shows: statusline config, all hook events, active plugins, 11 agent types, 18 skills, journal summary, and current session telemetry.

## Features

- **Burn rate + runway prediction** — Linear regression predicts when you'll hit limits. Warns only when you're on track to exhaust quota before reset.
- **Session journal** — Stop hook records every session: cost, lines, duration, context peak, tool count, repo.
- **Live telemetry** — PostToolUse hook counts every tool call. Shows velocity (tools/min) when in flow.
- **Context velocity** — Arrows show how fast your context window is filling.
- **Peak hours** — Warns during Anthropic's 2x consumption window.
- **Harness summary** — Hooks, plugins, agents, skills count at a glance.
- **One color palette** — Traffic-light gradient (green → amber → red). No theme bloat.
- **Smart layout** — Adapts to terminal width. Drops low-priority widgets to fit.
- **Zero dependencies** — Pure Python stdlib. No pip, no npm, no cargo.
- **Sub-50ms** — Aggressive caching. Hot path is <10ms.
- **Currency conversion** — Live exchange rates, cached 24h. 17 currencies.
- **Never crashes** — Graceful fallback on any error. Always shows something.

## Configure

```bash
~/.claude-statusline/statusline.py --config           # Show settings
~/.claude-statusline/statusline.py --demo             # Preview the bar
~/.claude-statusline/statusline.py --currency £        # Set currency
~/.claude-statusline/statusline.py --bar-width large   # small/medium/large/xl or 4-20
~/.claude-statusline/statusline.py --show burn_rate    # Enable a widget
~/.claude-statusline/statusline.py --hide peak         # Disable a widget
~/.claude-statusline/statusline.py --peak-hours 13:00-19:00  # Set peak window
~/.claude-statusline/statusline.py --reset             # Factory reset
```

### Widgets

`session` · `weekly` · `context` · `cost` · `model` · `git` · `effort` · `lines` · `telemetry` · `harness` · `duration` · `peak` · `burn_rate` · `runway_alert` · `reset_timer` · `context_velocity`

## How it works

Claude Code pipes JSON to stdin on each interaction. This script parses it, computes derived metrics (burn rate via linear regression, context velocity, runway prediction), and outputs an ANSI-colored status line.

**Three data layers:**
1. **Stdin** — model, context, cost, lines, rate limits (from Claude Code, every refresh)
2. **PostToolUse hook** — tool counter, velocity, last tool name (live telemetry)
3. **Stop hook** — session summary written to journal (persists across sessions)

No API calls, no token consumption — everything runs locally.

## Requirements

- Python 3.8+
- Claude Code (any recent version; rate limit bars require v2.1.80+)

## License

MIT
