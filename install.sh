#!/bin/bash
# ============================================================================
# claude-code-statusline installer
# ============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/statusline.py"

# ── Check Python ─────────────────────────────────────────────────────────────

PYTHON=""
for candidate in python3.14 python3.13 python3.12 python3.11 python3; do
    if command -v "$candidate" &>/dev/null; then
        PYTHON="$candidate"
        break
    fi
done

if [ -z "$PYTHON" ]; then
    echo "Error: python3 is required. Install it and retry."
    exit 1
fi

PY_VERSION=$("$PYTHON" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
PY_MAJOR=$("$PYTHON" -c "import sys; print(sys.version_info.major)")
PY_MINOR=$("$PYTHON" -c "import sys; print(sys.version_info.minor)")

if [ "$PY_MAJOR" -lt 3 ] || { [ "$PY_MAJOR" -eq 3 ] && [ "$PY_MINOR" -lt 8 ]; }; then
    echo "Error: Python 3.8+ required (found $PY_VERSION)"
    exit 1
fi

echo "Using $PYTHON ($PY_VERSION)"

# ── Make executable ──────────────────────────────────────────────────────────

chmod +x "$SCRIPT"

# ── Configure Claude Code ────────────────────────────────────────────────────

PYTHON_PATH="$(command -v "$PYTHON")"
SETTINGS="$HOME/.claude/settings.json"
COMMAND="$PYTHON_PATH \"$SCRIPT\""

if [ -f "$SETTINGS" ]; then
    if grep -q "statusline.py" "$SETTINGS" 2>/dev/null; then
        echo "Already configured in $SETTINGS"
        echo "Updating command path..."
    fi
    "$PYTHON" -c "
import json, sys
with open('$SETTINGS') as f:
    cfg = json.load(f)
cfg['statusLine'] = {'type': 'command', 'command': '$COMMAND'}
with open('$SETTINGS', 'w') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')
"
else
    mkdir -p "$(dirname "$SETTINGS")"
    "$PYTHON" -c "
import json
cfg = {'statusLine': {'type': 'command', 'command': '$COMMAND'}}
with open('$SETTINGS', 'w') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')
"
fi

echo ""
echo "Installed claude-code-statusline"
echo "  Script:   $SCRIPT"
echo "  Settings: $SETTINGS"
echo ""
echo "Restart Claude Code to see your new status bar."
echo ""
echo "Configure:"
echo "  $PYTHON $SCRIPT --demo      Preview"
echo "  $PYTHON $SCRIPT --config    Current settings"
echo "  $PYTHON $SCRIPT --help      All options"
