# VaydeAOS

A minimal native macOS app base built with Swift and SwiftUI.

The [Hello World example](examples/hello-world/) opens a single window displaying
`Hello, world!`. A shell script compiles the source into a standard macOS `.app`
bundle.

## Build and run

Requires macOS 11 or later and Xcode Command Line Tools
(`xcode-select --install`).

From the repository root:

```sh
./examples/hello-world/build.sh
open examples/hello-world/build/HelloWorld.app
```

The example includes its SwiftUI source, app metadata, and build script.
Generated build files are ignored by Git.
