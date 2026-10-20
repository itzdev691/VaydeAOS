#!/bin/sh
set -eu

example_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
app_dir="$example_dir/build/HelloWorld.app"

mkdir -p "$app_dir/Contents/MacOS"
xcrun swiftc -parse-as-library \
    -target "$(uname -m)-apple-macosx11.0" \
    -framework SwiftUI \
    "$example_dir/HelloWorld.swift" \
    -o "$app_dir/Contents/MacOS/HelloWorld"
cp "$example_dir/Info.plist" "$app_dir/Contents/Info.plist"

printf 'Built %s\n' "$app_dir"
