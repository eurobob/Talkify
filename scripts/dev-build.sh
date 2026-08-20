#!/bin/sh
# Builds Talkify and runs it, signed with your own Apple Development team.
#
# The committed project carries the upstream author's team, so a plain
# `xcodebuild` fails with "No signing certificate Mac Development found".
# This script overrides the team on the command line and leaves the project
# file untouched, so the fork stays easy to merge from upstream.
#
#   ./scripts/dev-build.sh            build, then launch
#   ./scripts/dev-build.sh --no-run   build only
set -eu

TEAM="${TALKIFY_TEAM:-SZP9K9CJAX}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

xcodebuild \
  -project Talkify.xcodeproj \
  -scheme Talkify \
  -configuration Debug \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM" \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY="Apple Development" \
  build

[ "${1:-}" = "--no-run" ] && exit 0

BUILD_DIR="$(
  xcodebuild -project Talkify.xcodeproj -scheme Talkify -configuration Debug \
    -showBuildSettings 2>/dev/null |
  awk '/ BUILT_PRODUCTS_DIR = /{ print $3; exit }'
)"
APP="$BUILD_DIR/Talkify.app"

if [ ! -d "$APP" ]; then
  echo "Built app not found at $APP" >&2
  exit 1
fi

# A second copy would fight the first one for the remote and the event tap.
osascript -e 'quit app "Talkify"' >/dev/null 2>&1 || true
open "$APP"
echo "Launched $APP"
