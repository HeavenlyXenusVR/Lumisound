#!/usr/bin/env bash
# Sets up the Lumisound Discord Rich Presence daemon as a macOS LaunchAgent
# (runs in the background, restarts on login).
#
# Usage:
#   ./install-macos.sh                     # sign in with email/username + password
#   ./install-macos.sh <rpc_token>         # or paste a Rich Presence token
#   ./install-macos.sh <rpc_token> <url>   # ...against a self-hosted bridge
#   ./install-macos.sh --bridge-url <url>  # sign in against a self-hosted bridge
#
# Signing in is the default because the Rich Presence token is 248 characters
# and pasting it reliably is awkward. Your password is exchanged for a 365-day
# token and is never written to disk -- see rpc_login.py.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST="$LAUNCH_AGENTS_DIR/com.lumisound.discord-rpc.plist"

if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 is required (the daemon itself runs on it)." >&2
    exit 1
fi

LOGIN_ARGS=()
case "${1:-}" in
    "")
        # Interactive sign-in.
        ;;
    --bridge-url)
        [ "$#" -ge 2 ] || { echo "Error: --bridge-url needs a URL." >&2; exit 1; }
        LOGIN_ARGS+=(--bridge-url "$2")
        ;;
    -h|--help)
        sed -n '2,13p' "$0"
        exit 0
        ;;
    *)
        # Positional form, kept for anyone following the older instructions:
        #   install-macos.sh <rpc_token> [bridge_url]
        LOGIN_ARGS+=(--token "$1")
        [ -n "${2:-}" ] && LOGIN_ARGS+=(--bridge-url "$2")
        ;;
esac

mkdir -p "$LAUNCH_AGENTS_DIR"

# Writes the config (mode 0600) at the daemon's own default_config_path().
python3 "$SCRIPT_DIR/rpc_login.py" "${LOGIN_ARGS[@]+"${LOGIN_ARGS[@]}"}"

PYTHON3="$(command -v python3)"

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.lumisound.discord-rpc</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PYTHON3</string>
        <string>$SCRIPT_DIR/lumisound_discord_rpc.py</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$CONFIG_DIR/daemon.log</string>
    <key>StandardErrorPath</key>
    <string>$CONFIG_DIR/daemon.log</string>
</dict>
</plist>
PLIST_EOF

echo "Installed $PLIST"

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo
echo "Started. Check status with:"
echo "  launchctl list | grep lumisound"
echo "  tail -f $CONFIG_DIR/daemon.log"
echo
echo "Stop with:"
echo "  launchctl unload $PLIST"
