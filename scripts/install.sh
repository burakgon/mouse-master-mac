#!/bin/bash
# Builds Mouse Master, installs it into /Applications, registers the background agent
# (starts at login, restarts if it ever crashes) and opens the app.
#
#   scripts/install.sh              build and install
#   scripts/install.sh --no-build   install the existing build
#   scripts/install.sh --uninstall  remove the app and the agent (settings are kept)
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="/Applications/Mouse Master.app"
LABEL="com.burakgon.MouseMaster.Agent"
DOMAIN="gui/$(id -u)"

stop_agent() {
    # SIGTERM makes the agent give every control its native behaviour back first.
    if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
        launchctl kill TERM "$DOMAIN/$LABEL" 2>/dev/null || true
    fi
    pkill -TERM -x MouseMasterAgent 2>/dev/null || true
    pkill -x "Mouse Master" 2>/dev/null || true
    for _ in $(seq 1 30); do
        pgrep -x MouseMasterAgent >/dev/null || break
        sleep 0.1
    done
}

if [[ "${1:-}" == "--uninstall" ]]; then
    stop_agent
    if [[ -x "$DEST/Contents/MacOS/Mouse Master" ]]; then
        launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    fi
    rm -rf "$DEST"
    rm -f /usr/local/bin/mmctl 2>/dev/null || true
    echo "Mouse Master removed. Settings remain in ~/Library/Application Support/Mouse Master."
    exit 0
fi

if [[ "${1:-}" != "--no-build" ]]; then
    scripts/build.sh
fi

echo "==> Installing into $DEST"
stop_agent
rm -rf "$DEST"
ditto "build/Mouse Master.app" "$DEST"

# mmctl on the PATH when possible.
if [[ -d /usr/local/bin && -w /usr/local/bin ]]; then
    ln -sf "$DEST/Contents/Helpers/mmctl" /usr/local/bin/mmctl
elif [[ -d /opt/homebrew/bin && -w /opt/homebrew/bin ]]; then
    ln -sf "$DEST/Contents/Helpers/mmctl" /opt/homebrew/bin/mmctl
fi

echo "==> Registering the background agent"
# macOS ties the registration to the app's signature, so it is renewed on every install.
# Right after the bundle is replaced the renewal can race; check and try again.
agent_running() { launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -q "state = running"; }
for attempt in 1 2 3 4; do
    "$DEST/Contents/MacOS/Mouse Master" --register-agent || true
    for _ in $(seq 1 25); do
        agent_running && break
        sleep 0.2
    done
    agent_running && break
    sleep 1
done
if agent_running; then
    echo "==> The agent is running"
else
    echo "!!  The agent did not start; open Mouse Master to finish setting it up."
fi
if [[ "${NO_OPEN:-}" != "1" ]]; then
    open "$DEST"
fi
