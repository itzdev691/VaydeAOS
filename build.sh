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
app_dir="${VAYDEAOS_APP_DIR:-$project_dir/build/VaydeAOS.app}"

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/VaydeAOS" "$app_dir/Contents/MacOS/VaydeAOS"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"

# Package the existing VaydeNet mark for Finder, the Dock, and the app switcher.
iconset_dir="$project_dir/build/VaydeAOS.iconset"
mkdir -p "$iconset_dir"
for size in 16 32 128 256 512; do
    sips --resampleHeightWidth "$size" "$size" \
        "$project_dir/Sources/VaydeAOS/Assets/vayde-mark.png" \
        --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    sips --resampleHeightWidth "$retina_size" "$retina_size" \
        "$project_dir/Sources/VaydeAOS/Assets/vayde-mark.png" \
        --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns "$iconset_dir" --output "$app_dir/Contents/Resources/VaydeAOS.icns"

# Console.assets loads this conventional bundle path when packaged.
resource_bundle="VaydeAOS_VaydeAOS.bundle"
ditto "$binary_dir/$resource_bundle" "$app_dir/Contents/Resources/$resource_bundle"
# Package the terminal renderer's resources alongside the app's resources.
ditto "$binary_dir/SwiftTerm_SwiftTerm.bundle" "$app_dir/Contents/Resources/SwiftTerm_SwiftTerm.bundle"
cp -f "$project_dir/.build/checkouts/SwiftTerm/LICENSE" "$app_dir/Contents/Resources/SwiftTerm-LICENSE.txt"
# Remove the obsolete development link if an earlier local build created it.
if [ -L "$app_dir/$resource_bundle" ]; then
    rm "$app_dir/$resource_bundle"
fi
# The unified ChatGPT connection is owned by Codex; remove obsolete helper resources.
if [ -d "$app_dir/Contents/Resources/ChatGPT" ]; then
    rm -rf "$app_dir/Contents/Resources/ChatGPT"
fi
VAYDEAOS_APP_DIR="$app_dir" python3 "$project_dir/scripts/prepare-codex-runtime.py"
codesign --force --sign - "$app_dir"

printf 'Built %s\n' "$app_dir"
