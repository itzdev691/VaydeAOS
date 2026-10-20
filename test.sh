#!/bin/sh
set -eu

project_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
developer_dir="$(xcode-select -p)"
cd "$project_dir"

# Recent Command Line Tools bundle Swift Testing outside the default search path.
# Xcode selects its own framework paths, so it does not need this adjustment.
framework_dir="$developer_dir/Library/Developer/Frameworks"
if [ -d "$framework_dir/Testing.framework" ]; then
    exec swift test --disable-xctest \
        -Xswiftc -F -Xswiftc "$framework_dir" \
        -Xlinker -rpath -Xlinker "$framework_dir" \
        -Xlinker -rpath -Xlinker "$developer_dir/Library/Developer/usr/lib" "$@"
fi

exec swift test --disable-xctest "$@"
