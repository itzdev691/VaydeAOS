#!/bin/sh
set -eu
project_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$project_dir"
swift build --product VaydeAOS
binary_dir="$(swift build --show-bin-path)"
mkdir -p build/console-validation
swiftc -parse-as-library -I "$binary_dir/Modules" \
    Sources/VaydeAOS/ProjectConsoleController.swift Sources/VaydeAOS/CLITerminalView.swift scripts/check-project-console.swift \
    "$binary_dir"/VaydeAOSCore.build/*.swift.o \
    "$binary_dir"/SwiftTerm.build/*.swift.o \
    -o build/console-validation/controller-check
build/console-validation/controller-check
