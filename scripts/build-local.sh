#!/bin/bash
# Local Coucou build with the STABLE Apple Development signing identity.
# Signing with this fixed identity (instead of ad-hoc "-") is what keeps
# macOS from re-asking keychain password after every rebuild: keychain items
# the app creates stay readable by the next build.
set -e
IDENTITY="23E39AB879E2130FD2FD33B82C942F6CD2FC586E"
cd "$(dirname "$0")/../NotchBuddy"

xcodegen
xcodebuild -project NotchBuddy.xcodeproj -scheme NotchBuddy -configuration Debug build ENABLE_DEBUG_DYLIB=NO -quiet

APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/NotchBuddy-*/Build/Products/Debug/Coucou.app | head -1)
mkdir -p ../build
rm -rf ../build/Coucou.app
cp -R "$APP" ../build/
codesign --force --deep -s "$IDENTITY" ../build/Coucou.app
xattr -dr com.apple.quarantine ../build/Coucou.app 2>/dev/null || true

echo "✅ Built: ../build/Coucou.app (signed $IDENTITY)"
