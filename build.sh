#!/bin/sh
set -eu
cd "$(dirname "$0")"

bundle="dist/shpshka app.app"
mkdir -p "$bundle/Contents/MacOS"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
for arch in arm64 x86_64; do
    swift build -c release --scratch-path ".build/$arch" --triple "$arch-apple-macosx"
    bin_dir=$(swift build -c release --scratch-path ".build/$arch" --triple "$arch-apple-macosx" --show-bin-path)
    cp "$bin_dir/NotchMusic" "$stage/$arch"
done
exe="$bundle/Contents/MacOS/NotchMusic"
lipo -create "$stage/arm64" "$stage/x86_64" -output "$exe"
strip -S -x "$exe"
install -m 644 Resources/Info.plist "$bundle/Contents/Info.plist"
codesign --force --sign - "$bundle"
codesign --verify --strict "$bundle"

mkdir "$stage/image"
ditto "$bundle" "$stage/image/shpshka app.app"
ln -s /Applications "$stage/image/Applications"
hdiutil create -ov -format UDZO -volname "shpshka app" -srcfolder "$stage/image" dist/shpshka-app.dmg
