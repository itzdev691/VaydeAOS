#!/bin/sh
set -eu
project_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
version=v22.23.4
case "$(uname -m)" in
    arm64) arch=arm64; checksum=c9e1dbc748b33ed2d14f42445191ecaf14c56259c7a9a26d0042c49ec2b66428 ;;
    x86_64) arch=x64; checksum=efcc2b0db6f94bf53eddb038fe2b370277a042bd29e4f19b8f8e23598795b819 ;;
    *) echo 'Unsupported Node runtime architecture' >&2; exit 1 ;;
esac
cache="$project_dir/build/chatgpt-runtime"
archive="node-$version-darwin-$arch.tar.gz"
mkdir -p "$cache"
if [ ! -f "$cache/$archive" ]; then
    curl --fail --location --proto '=https' --tlsv1.2 --retry 2 \
        "https://nodejs.org/dist/$version/$archive" -o "$cache/$archive.partial"
    mv "$cache/$archive.partial" "$cache/$archive"
fi
printf '%s  %s\n' "$checksum" "$cache/$archive" | shasum -a 256 -c -
runtime="$cache/node-$version-darwin-$arch"
# Re-extract verified bytes rather than trusting previously cached executables.
tar -xzf "$cache/$archive" -C "$cache"
export PATH="$runtime/bin:$PATH"
cd "$project_dir/Helpers/ChatGPT"
npm ci --ignore-scripts --no-audit --no-fund
npm run build
destination="$project_dir/build/VaydeAOS.app/Contents/Resources/ChatGPT"
mkdir -p "$destination"
cp dist/helper.mjs dist/THIRD_PARTY_NOTICES.txt "$destination/"
cp vendor/siwc-local/LICENSE "$destination/DEVKIT_LICENSE.txt"
cp "$runtime/bin/node" "$destination/node"
cp "$runtime/LICENSE" "$destination/NODE_LICENSE.txt"
xcrun swiftc -O -target "$(uname -m)-apple-macosx13.0" CredentialVault.swift -o "$destination/credential-vault"
codesign --force --sign - --identifier dev.vaydeaos.chatgpt.node "$destination/node"
codesign --force --sign - --identifier dev.vaydeaos.chatgpt.vault "$destination/credential-vault"
