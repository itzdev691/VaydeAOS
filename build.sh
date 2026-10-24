#!/bin/sh
set -eu

project_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
configuration="${1:-debug}"

case "$configuration" in
    debug|release) ;;
    *) printf 'Usage: %s [debug|release]\n' "$0" >&2; exit 1 ;;
esac

cd "$project_dir"
swift build --configuration "$configuration" --product VaydeAOS
binary_dir="$(swift build --configuration "$configuration" --show-bin-path)"
app_dir="$project_dir/build/VaydeAOS.app"

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/VaydeAOS" "$app_dir/Contents/MacOS/VaydeAOS"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"

# Console.assets loads this conventional bundle path when packaged.
resource_bundle="VaydeAOS_VaydeAOS.bundle"
ditto "$binary_dir/$resource_bundle" "$app_dir/Contents/Resources/$resource_bundle"
# Remove the obsolete development link if an earlier local build created it.
if [ -L "$app_dir/$resource_bundle" ]; then
    rm "$app_dir/$resource_bundle"
fi
# The unified ChatGPT connection is owned by Codex; remove obsolete helper resources.
if [ -d "$app_dir/Contents/Resources/ChatGPT" ]; then
    rm -rf "$app_dir/Contents/Resources/ChatGPT"
fi
python3 "$project_dir/scripts/prepare-codex-runtime.py"
codesign --force --sign - "$app_dir"

printf 'Built %s\n' "$app_dir"
