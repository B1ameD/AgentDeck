#!/bin/zsh
set -euo pipefail

APP_NAME="AgentDeck"
BUNDLE_ID="com.agentdeck.app"
VERSION="0.1.0"
SKIP_BUILD=0
BUILD_PATH=".build"
OUTPUT_PATH="dist"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --build-path)
      BUILD_PATH="$2"
      shift 2
      ;;
    --output)
      OUTPUT_PATH="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 64
      ;;
  esac
done

SCRIPT_DIR="${0:A:h}"
PACKAGE_ROOT="${SCRIPT_DIR:h}"
cd "$PACKAGE_ROOT"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  swift build -c release
fi

EXECUTABLE_PATH="$BUILD_PATH/release/$APP_NAME"
if [[ ! -x "$EXECUTABLE_PATH" ]]; then
  echo "Missing executable at $EXECUTABLE_PATH" >&2
  exit 66
fi

APP_ROOT="$OUTPUT_PATH/$APP_NAME.app"
CONTENTS_DIR="$APP_ROOT/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
PACKAGE_RESOURCES_DIR="Sources/AgentDeckApp/Resources"

rm -rf "$APP_ROOT"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$EXECUTABLE_PATH" "$MACOS_DIR/$APP_NAME"
chmod 755 "$MACOS_DIR/$APP_NAME"

if [[ -d "$PACKAGE_RESOURCES_DIR" ]]; then
  cp -R "$PACKAGE_RESOURCES_DIR/"* "$RESOURCES_DIR/"
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "Created $APP_ROOT"
