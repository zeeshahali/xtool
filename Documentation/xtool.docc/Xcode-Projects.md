# Build Xcode Projects

Build an existing `.xcodeproj` — such as one exported by Unity — into an iOS app or IPA on Linux, WSL, or macOS.

## Overview

`xtool xcodebuild` reads an Xcode project and builds it for iOS devices without Xcode. It is designed for generated projects like Unity's `Unity-iPhone.xcodeproj`, so a pipeline that previously required a Mac can run on Linux or Windows (via WSL).

> Note: You need the Darwin SDK on Linux/WSL. Run `xtool setup` first if you haven't already.

## What you need

| | Unsigned IPA | Signed IPA |
|---|---|---|
| **Linux** | xtool, Swift 6.4, `zip`, Darwin SDK | Same, plus an Apple ID (`xtool auth`) |
| **Windows** | WSL 2 with the Linux requirements | Same, plus an Apple ID (`xtool auth`) |
| **Unity** | Unity Editor with **iOS Build Support** to export the project | Same |
| **Xcode** | `Xcode.xip` 27.x to create the Darwin SDK (no Mac needed) | Same |
| **iPhone** | Not needed | Must be registered to your Apple developer team to install the IPA |

See <doc:Building-from-Source> to install xtool and these prerequisites. The Unity Editor can run on Windows, macOS or Linux. Only its export step is used, and you can run that on a different machine from the build.

## Building a Unity project

1. In Unity, choose **File > Build Settings > iOS > Build** to export the Xcode project (for example, into `Builds/iOS`).
2. Build it with xtool:

```bash
cd Builds/iOS
xtool xcodebuild --ipa
```

This builds the first application target (`Unity-iPhone`) and its dependencies (`GameAssembly`, `UnityFramework`) using the project's default configuration, and writes `build/<ProductName>.ipa` (named after the app, for example `build/MyGame.ipa`).

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

Like an Xcode archive, the IPA is compressed and its binaries are stripped of debug information and local symbols (following `STRIP_STYLE`). To keep symbols, pass `STRIP_INSTALLED_PRODUCT=NO`. No dSYM is generated.

## Signed builds

`--sign` signs the app with your Apple ID, on Linux and Windows (WSL) alike:

1. Sign in once with `xtool auth` (or `xtool setup`). Either login mode works:
    - **API Key** needs a paid Apple Developer Program membership.
    - **Password** works with a free Apple ID. Apple limits free accounts: their provisioning profiles expire after 7 days, so you rebuild and reinstall weekly.
2. Build with `--sign`:

    ```bash
    xtool xcodebuild --sign --ipa -o Game.ipa
    ```

    xtool creates or reuses a development certificate, registers the App ID for the bundle identifier, and embeds a development provisioning profile. Set the bundle identifier with `PRODUCT_BUNDLE_IDENTIFIER=...` if Unity's isn't one you can register.
3. Install it on an iPhone. The profile covers only devices registered to your team. The easiest way is to connect the iPhone and run `xtool install Game.ipa`, which registers the device and installs the app. `xtool install` re-signs the app for that device, so it also accepts an unsigned IPA. `--sign` matters when you install the IPA some other way, or send it to someone else.

These are development builds, for installing on your own devices. App Store and TestFlight distribution builds aren't supported.

Builds are incremental: object files are reused when their sources, included headers, and compiler flags are unchanged. Use `-j` to control parallelism and `--build-dir` to choose where intermediates go.

> Tip: If your Unity export is stored in Git LFS, make sure the large files (`Libraries/*.a`, `Data/*`) are actually downloaded (`git lfs pull`), not LFS pointer files.

## What's supported

- Build settings with `$(inherited)`, macro expansion, conditional settings (`[sdk=iphoneos*]`) and `.xcconfig` files
- Target dependencies, including implicit dependencies on other targets' products
- C, C++, Objective-C, Objective-C++, assembly and Swift sources, with per-file compiler flags and prefix headers
- Xcode-style header maps (so `#include "Foo.h"` finds any header in the project)
- Applications, frameworks, static and dynamic libraries, bundles and app extensions
- Linking against SDK frameworks, `.a`, `.tbd`, `.framework` and `.xcframework` files
- Resources, including folder references (like Unity's `Data` folder) and localized `.lproj` files
- Copy Files phases (e.g. "Embed Frameworks")
- Unity's IL2CPP step: the `GameAssembly` target's script runs Unity's `il2cpp` tool, which only works on macOS/Windows. xtool recognizes it and compiles the generated C++ (`Il2CppOutputProject/Source/il2cppOutput`) into `libGameAssembly.a` itself
- Other Run Script phases, when `--run-scripts` is passed (they're skipped by default since they often call macOS-only tools)

## Limitations

Some resources can only be compiled by Apple's macOS-only tools, and are skipped with a warning:

- **Storyboards and XIBs.** If the launch screen storyboard is skipped, xtool replaces `UILaunchStoryboardName` with an empty `UILaunchScreen` entry so the app still launches full-screen.
- **Asset catalogs**, except the app icon, which is copied as loose PNG files referenced by `CFBundleIcons`.
- Core Data models, Metal shaders, string catalogs and similar Xcode-compiled resources.

Only `arm64` iOS device builds are produced.
