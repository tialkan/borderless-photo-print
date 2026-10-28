#!/bin/sh
# Builds "Fotoğraf Çıktı.app" into ./build (Apple silicon or Intel, ad-hoc signed).
set -e
cd "$(dirname "$0")"
APP="build/Fotoğraf Çıktı.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -parse-as-library Sources/*.swift -o "$APP/Contents/MacOS/FotografCikti"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built: $APP"
