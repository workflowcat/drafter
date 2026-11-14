#!/bin/zsh
# Builds ~/Applications/Drafter.app (Command Line Tools only, no Xcode).
set -e
cd "${0:A:h}"
APP=~/Applications/Drafter.app
# The bundle id comes from the local config (build.bundle_id), else the public default in engine/local.py. Changing it on a
# Mac that already granted Accessibility, Microphone etc. resets those grants.
ID=$(/usr/bin/python3 ../engine/local.py --get bundle_id)
mkdir -p build
swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx15.0 *.swift -o build/Drafter
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/Drafter "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp icon/Drafter.icns "$APP/Contents/Resources/"
cp -R art "$APP/Contents/Resources/"   # PixelKit fonts and sprites (app/art/README.md)
/usr/libexec/PlistBuddy -c "Add :DrafterHome string ${PWD:h}" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" "$APP/Contents/Info.plist"
# Fixed requirement, so macOS keeps the Accessibility and Calendar grants across rebuilds.
codesign --force -s - -r="designated => identifier \"$ID\"" "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "Built $APP"
