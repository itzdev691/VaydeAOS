# Hello World for macOS

A native SwiftUI app: one window displaying `Hello, world!`.

Requires macOS 11 or later and Apple's Xcode Command Line Tools (`xcode-select --install`).

Build and launch from this directory:

```sh
./build.sh
open build/HelloWorld.app
```

The app code is in `HelloWorld.swift`. The build script compiles it and packages
the executable with `Info.plist` into `build/HelloWorld.app`.
