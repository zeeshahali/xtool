# Build Xcode Projects

Build an existing `.xcodeproj` — such as one exported by Unity — into an iOS app or IPA on Linux, WSL, or macOS.

## Overview

`xtool xcodebuild` reads an Xcode project and builds it for iOS devices without Xcode. It is designed for generated projects like Unity's `Unity-iPhone.xcodeproj`, so a pipeline that previously required a Mac can run on Linux or Windows (via WSL).

> Note: You need the Darwin SDK on Linux/WSL. Run `xtool setup` first if you haven't already.

## Building a Unity project

1. In Unity, choose **File > Build Settings > iOS > Build** to export the Xcode project (for example, into `Builds/iOS`).
2. Build it with xtool:

```bash
cd Builds/iOS
xtool xcodebuild --ipa
```

This builds the first application target (`Unity-iPhone`) and its dependencies (`UnityFramework`) using the project's default configuration, and writes `build/Unity-iPhone.ipa`.

Common options:

```bash
# list targets and configurations
xtool xcodebuild --list

# pick the project, target and configuration (xcodebuild-style flags also work)
xtool xcodebuild -project Unity-iPhone.xcodeproj -target Unity-iPhone -configuration Release --ipa

# override build settings, like xcodebuild
xtool xcodebuild --ipa PRODUCT_BUNDLE_IDENTIFIER=com.example.game

# sign with your Apple ID (after `xtool auth`) and install to a connected device
xtool xcodebuild --sign --ipa -o Game.ipa
xtool install Game.ipa
```

Without `--sign`, the IPA is unsigned (or ad-hoc signed if the target has `CODE_SIGN_ENTITLEMENTS`), ready for any signing step later in your pipeline.

Builds are incremental: object files are reused when their sources, included headers, and compiler flags are unchanged. Use `-j` to control parallelism and `--build-dir` to choose where intermediates go.

## What's supported

- Build settings with `$(inherited)`, macro expansion, conditional settings (`[sdk=iphoneos*]`) and `.xcconfig` files
- Target dependencies, including implicit dependencies on other targets' products
- C, C++, Objective-C, Objective-C++, assembly and Swift sources, with per-file compiler flags and prefix headers
- Xcode-style header maps (so `#include "Foo.h"` finds any header in the project)
- Applications, frameworks, static and dynamic libraries, bundles and app extensions
- Linking against SDK frameworks, `.a`, `.tbd`, `.framework` and `.xcframework` files
- Resources, including folder references (like Unity's `Data` folder) and localized `.lproj` files
- Copy Files phases (e.g. "Embed Frameworks")
- Run Script phases, when `--run-scripts` is passed (they're skipped by default since they often call macOS-only tools)

## Limitations

Some resources can only be compiled by Apple's macOS-only tools, and are skipped with a warning:

- **Storyboards and XIBs.** If the launch screen storyboard is skipped, xtool replaces `UILaunchStoryboardName` with an empty `UILaunchScreen` entry so the app still launches full-screen.
- **Asset catalogs**, except the app icon, which is copied as loose PNG files referenced by `CFBundleIcons`.
- Core Data models, Metal shaders, string catalogs and similar Xcode-compiled resources.

Only `arm64` iOS device builds are produced.
