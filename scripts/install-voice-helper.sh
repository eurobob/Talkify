#!/bin/sh
# Installs the Siri Remote voice helper as a launchd daemon.
#
# Run this once. After it, the remote's microphone works whenever the app
# runs: no terminal window, no script, no password. The helper starts at
# boot, and it only spawns PacketLogger while the app is actually
# connected, so it costs nothing when nobody is dictating.
#
# It needs root for one reason: macOS lets only root read the Bluetooth
# link, and an app cannot elevate itself. That is the whole reason this is
# a daemon rather than something inside the app.
#
#   ./scripts/install-voice-helper.sh              install or update
#   ./scripts/install-voice-helper.sh --uninstall  remove it entirely
set -eu

LABEL="digital.chaotic.talkify-remote-voiced"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
INSTALLED="/usr/local/libexec/talkify-remote-voiced"
SOCKET="/var/run/talkify-remote-voice.sock"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$PROJECT_DIR/helper"
VOICE_DIR="$PROJECT_DIR/Talkify/RemoteInput/Voice"

if [ "$(id -u)" -ne 0 ]; then
  echo "Installing a launchd daemon needs root. Elevating."
  exec sudo "$0" "$@"
fi

if [ "${1:-}" = "--uninstall" ]; then
  launchctl bootout "system/$LABEL" 2>/dev/null || true
  rm -f "$PLIST" "$INSTALLED" "$SOCKET"
  echo "Removed the voice helper."
  exit 0
fi

echo "Building the helper…"
swiftc -O \
  "$SOURCE_DIR/main.swift" \
  "$VOICE_DIR/BluetoothTrace.swift" \
  "$VOICE_DIR/SiriRemoteVoiceFrame.swift" \
  "$VOICE_DIR/OpusDecoder.swift" \
  "$VOICE_DIR/SiriRemoteVoiceStream.swift" \
  -o "$SOURCE_DIR/talkify-remote-voiced"

mkdir -p /usr/local/libexec
install -m 755 "$SOURCE_DIR/talkify-remote-voiced" "$INSTALLED"
echo "Installed $INSTALLED"

cat > "$PLIST" <<PLIST_END
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$INSTALLED</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardErrorPath</key>
	<string>/var/log/talkify-remote-voiced.log</string>
</dict>
</plist>
PLIST_END

chown root:wheel "$PLIST"
chmod 644 "$PLIST"

# bootout first, so re-running this replaces a live daemon rather than
# failing on one that is already loaded.
launchctl bootout "system/$LABEL" 2>/dev/null || true
launchctl bootstrap system "$PLIST"

sleep 2
if launchctl print "system/$LABEL" >/dev/null 2>&1; then
  echo
  echo "The voice helper is running and will start at boot."
  echo "Its log is /var/log/talkify-remote-voiced.log"
  echo
  echo "You can close every terminal now. Dictation works whenever the app runs."
else
  echo "The daemon did not start. See /var/log/talkify-remote-voiced.log" >&2
  exit 1
fi
