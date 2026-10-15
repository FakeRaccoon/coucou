#!/bin/bash
# Local Coucou build with the STABLE Apple Development signing identity.
# Signing with this fixed identity (instead of ad-hoc "-") is what keeps
# macOS from re-asking keychain password after every rebuild: keychain items
# the app creates stay readable by the next build.
set -e
IDENTITY="286DB909645946F94705C5A5B0A617265E1D20A5" # "Coucou Dev" — self-signed, no Apple team
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
