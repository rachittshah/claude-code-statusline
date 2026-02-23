#!/bin/bash
# ============================================================================
# Claude Code Status Line - Cross-Platform Installer
# ============================================================================
# Installs scripts to ~/.claude/statusline/ and configures settings.json
# Supports macOS and Linux
# ============================================================================

set -euo pipefail

INSTALL_DIR="$HOME/.claude/statusline"
SETTINGS_FILE="$HOME/.claude/settings.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Claude Code Status Line Installer ==="
echo ""

# Detect OS
OS="$(uname -s)"
case "$OS" in
    Darwin) echo "Platform: macOS" ;;
    Linux)  echo "Platform: Linux" ;;
    *)      echo "Unsupported platform: $OS"; exit 1 ;;
esac

# Check jq
if ! command -v jq &>/dev/null; then
    echo ""
    echo "jq is required but not installed."
    case "$OS" in
        Darwin) echo "Install with: brew install jq" ;;
        Linux)  echo "Install with: sudo apt-get install -y jq" ;;
    esac
    read -rp "Install jq now? [Y/n] " answer
    case "${answer:-y}" in
        [Yy]*)
            case "$OS" in
                Darwin) brew install jq ;;
                Linux)  sudo apt-get install -y jq ;;
            esac
            ;;
        *) echo "Please install jq and re-run."; exit 1 ;;
    esac
fi
echo "jq: $(command -v jq)"

# Check bun (optional, for usage tracking)
bun_found=""
for candidate in "$HOME/.bun/bin/bun" "/usr/local/bin/bun" "/opt/homebrew/bin/bun"; do
    if [[ -x "$candidate" ]]; then
        bun_found="$candidate"
        break
    fi
done
[[ -z "$bun_found" ]] && bun_found=$(command -v bun 2>/dev/null || true)

if [[ -n "$bun_found" ]]; then
    echo "bun: $bun_found (usage tracking enabled)"
else
    echo "bun: not found (usage tracking will be limited)"
    echo "  Install for full usage tracking: curl -fsSL https://bun.sh/install | bash"
fi

# Copy scripts
echo ""
echo "Installing to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"

for script in statusline.sh usage-detector.sh usage-bar.sh; do
    if [[ -f "$SCRIPT_DIR/$script" ]]; then
        cp "$SCRIPT_DIR/$script" "$INSTALL_DIR/"
        echo "  Copied $script"
    fi
done
chmod +x "$INSTALL_DIR"/*.sh
echo "Scripts installed."

# Configure settings.json
echo ""
if [[ -f "$SETTINGS_FILE" ]]; then
    existing=$(jq -r '.statusLine.command // empty' "$SETTINGS_FILE" 2>/dev/null) || existing=""
    if [[ -n "$existing" ]] && [[ "$existing" == *"statusline.sh"* ]]; then
        echo "settings.json: statusLine already configured"
        echo "  command: $existing"
    else
        echo "Updating $SETTINGS_FILE..."
        jq '.statusLine = {"type": "command", "command": "$HOME/.claude/statusline/statusline.sh"}' \
            "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp" && mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
        echo "settings.json: statusLine configured."
    fi
else
    echo "Creating $SETTINGS_FILE..."
    mkdir -p "$(dirname "$SETTINGS_FILE")"
    cat > "$SETTINGS_FILE" <<'SETTINGS'
{
  "statusLine": {
    "type": "command",
    "command": "$HOME/.claude/statusline/statusline.sh"
  }
}
SETTINGS
    echo "settings.json: created with statusLine."
fi

echo ""
echo "=== Installation complete! ==="
echo "Restart Claude Code to see the new status line."
