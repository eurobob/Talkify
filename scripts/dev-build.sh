#!/bin/sh
# Builds this fork and runs it, signed with your own Apple Development team.
#
# Two overrides matter, and both exist to keep the fork out of the released
# Talkify's way.
#
# The team: the committed project carries the upstream author's team, so a
# plain `xcodebuild` fails with "No signing certificate Mac Development
# found".
#
# The identity: the fork must not share a bundle identifier with a released
# Talkify. macOS grants Accessibility and Input Monitoring to a bundle
# identifier plus a signature. The released app already holds the grant for
# com.tgomareli.Talkify under the author's team, so a fork signed by anyone
# else is a stranger claiming that name: the switch in System Settings stays
# on, and the permission still does not apply. Its own identifier gives the
# fork its own row, its own grants, and its own preferences.
#
# Both overrides live here rather than in the project file, so merges from
# upstream stay clean.
#
#   ./scripts/dev-build.sh            build, then launch
#   ./scripts/dev-build.sh --no-run   build only
set -eu

TEAM="${TALKIFY_TEAM:-SZP9K9CJAX}"
BUNDLE_ID="${TALKIFY_BUNDLE_ID:-digital.chaotic.TalkifyRemote}"
APP_NAME="${TALKIFY_APP_NAME:-Talkify Remote}"

# Its own derived data, and this is not a preference. `xcodebuild test`
# builds the plain "Talkify" product into the shared products directory and
# deletes "Talkify Remote.app" as it goes. The app keeps running from the
# deleted bundle, macOS can no longer validate it, and every TCC permission
# it holds stops working — the microphone included. That failure looks
# exactly like a broken app: dictation opens and no audio ever arrives.
DERIVED="${TALKIFY_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/TalkifyRemote-dev}"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

xcodebuild \
  -project Talkify.xcodeproj \
  -scheme Talkify \
  -configuration Debug \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM" \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY="Apple Development" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  PRODUCT_NAME="$APP_NAME" \
  build

[ "${1:-}" = "--no-run" ] && exit 0

APP="$DERIVED/Build/Products/Debug/$APP_NAME.app"

if [ ! -d "$APP" ]; then
  echo "Built app not found at $APP" >&2
  exit 1
fi

# Only this fork is quit, never a released Talkify beside it. A second copy
# of the fork would fight the first one for the remote and the event tap.
osascript -e "quit app \"$APP_NAME\"" >/dev/null 2>&1 || true
open "$APP"
echo "Launched $APP"
echo
echo "First run: grant Accessibility and Input Monitoring to \"$APP_NAME\","
echo "then quit and reopen it. macOS applies both only at launch."
