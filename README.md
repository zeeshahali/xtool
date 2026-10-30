# xtool

Cross-platform Xcode replacement. Build and deploy iOS apps with SwiftPM on Linux, Windows, and macOS.

## Overview

xtool is a cross-platform (Linux/WSL/macOS) tool that replicates Xcode functionality with open standards.

✅ Build a SwiftPM package into an iOS app

✅ Build an Xcode project (e.g. exported from Unity) into an iOS app or IPA with `xtool xcodebuild`, signed or unsigned, on Linux and Windows without a Mac

✅ Sign and install iOS apps

✅ Interact with Apple Developer Services programmatically

## Getting Started

1. Follow the guide to install `xtool`
    - [Installation (Linux/Windows)](https://xtool.sh/documentation/xtooldocs/installation-linux)
    - [Installation (macOS)](https://xtool.sh/documentation/xtooldocs/installation-macos)
    - [Building from source (Linux/Windows)](Documentation/xtool.docc/Building-from-Source.md): prerequisites and steps, needed for `xtool xcodebuild` until it's released
2. Create and run your first xtool-powered app by following the [tutorial](https://xtool.sh/tutorials/xtooldocs/first-app)!

## Building Unity projects for iOS

Export your Unity project for iOS (**File > Build Settings > iOS > Build**), then build it on Linux or Windows (WSL):

```bash
cd Builds/iOS
xtool xcodebuild --ipa                    # unsigned IPA
xtool xcodebuild --sign --ipa -o Game.ipa # signed with your Apple ID (after `xtool auth`)
xtool install Game.ipa                    # install on a connected iPhone
```

What you need:

| | Unsigned IPA | Signed IPA |
|---|---|---|
| **Linux** | xtool, Swift 6.4, `zip`, Darwin SDK | Same, plus an Apple ID (`xtool auth`) |
| **Windows** | WSL 2 with the Linux requirements | Same, plus an Apple ID (`xtool auth`) |
| **Unity** | Unity Editor with iOS Build Support | Same |
| **Xcode** | `Xcode.xip` 27.x, to create the Darwin SDK (no Mac needed) | Same |
| **iPhone** | Not needed | Registered to your Apple developer team, to install |

Release builds also write dSYMs for crash symbolication, next to the build products (for example `build/Build/Products/Release-iphoneos/UnityFramework.framework.dSYM`), and the IPA is compressed and stripped like an Xcode archive.

A free Apple ID works for signing, but its profiles expire after 7 days, and a device can hold at most 3 apps signed with free accounts. See [Build Xcode Projects](Documentation/xtool.docc/Xcode-Projects.md) for options, signing and limitations, and [Building from source](Documentation/xtool.docc/Building-from-Source.md) for setup.

## Examples

### Screenshot

![A screenshot of xtool being invoked from VSCode](Documentation/xtool.docc/Resources/Cover.png)

### Command line interface

```bash
$ xtool --help
OVERVIEW: Cross-platform Xcode replacement

USAGE: xtool <subcommand>

OPTIONS:
  --version               Show the version.
  -h, --help              Show help information.

CONFIGURATION SUBCOMMANDS:
  setup                   Set up xtool for iOS development
  auth                    Manage Apple Developer Services authentication
  sdk                     Manage the Darwin Swift SDK

DEVELOPMENT SUBCOMMANDS:
  new                     Create a new xtool SwiftPM project
  dev                     Build and run an xtool SwiftPM project
  xcodebuild              Build an Xcode project (.xcodeproj) into an iOS app or IPA
  ds                      Interact with Apple Developer Services

DEVICE SUBCOMMANDS:
  devices                 List devices
  install                 Install an ipa file to your device
  uninstall               Uninstall an installed app
  launch                  Launch an installed app

  See 'xtool help <subcommand>' for detailed help.
```

Build an Xcode project, such as a Unity export, into an app or IPA:

```bash
$ xtool xcodebuild --help
OVERVIEW: Build an Xcode project (.xcodeproj) into an iOS app or IPA

USAGE: xtool xcodebuild [--project <project>] [--target <target>] [--configuration <configuration>] [--build-dir <build-dir>] [--jobs <jobs>] [--run-scripts] [--sign] [--ipa] [--output <output>] [--verbose] [--list] [<settings> ...]

ARGUMENTS:
  <settings>              Build setting overrides in the form KEY=VALUE.

OPTIONS:
  --project, -project <project>
                          Path to the .xcodeproj to build. Defaults to the only .xcodeproj in the
                          current directory.
  --target, -target <target>
                          Target to build. Defaults to the first application target.
  -c, --configuration, -configuration <configuration>
                          Build configuration, e.g. Debug or Release. Defaults to the project's
                          default.
  --build-dir <build-dir> Directory for build products and intermediates. Defaults to <project
                          dir>/build.
  -j, --jobs <jobs>       Number of parallel compile jobs. (default: number of CPU cores)
  --run-scripts           Run 'Run Script' build phases (skipped by default since they often call
                          macOS-only tools).
  -s, --sign              Codesign the built app with your Apple ID (requires `xtool auth`).
  -i, --ipa               Output a .ipa file instead of a .app
  -o, --output <output>   Where to write the final .app or .ipa. Defaults to the build directory.
  -v, --verbose           Print every command that is executed.
  --list                  List the project's targets and configurations, then exit.
  --version               Show the version.
  -h, --help              Show help information.
```

For example, to build a Unity export into an unsigned IPA, or a signed one you can install:

```bash
cd Builds/iOS
xtool xcodebuild --ipa
xtool xcodebuild --ipa --sign -o Game.ipa && xtool install Game.ipa
```

### Library

You can consume xtool itself as a Swift Package, to enable your own app to interact with Apple Developer Services, iOS devices, and more. You can use this by adding `XKit` or `XToolSupport` as a SwiftPM dependency.

Note: while we aim to uphold semver semantics on the CLI interface (breaking change = major version bump), the Swift interface does not offer the same guarantees.

```swift
// package dependency:
.package(url: "https://github.com/xtool-org/xtool", .upToNextMinor(from: "1.2.0"))
// target dependency:
.product(name: "XKit", package: "xtool")
```
