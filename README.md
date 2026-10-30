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

### Library

xtool includes a library that you can use to interact with Apple Developer Services, iOS devices, and more from your own app. You can use this by adding `XKit` as a SwiftPM dependency.

```swift
// package dependency:
.package(url: "https://github.com/xtool-org/xtool", .upToNextMinor(from: "1.2.0"))
// target dependency:
.product(name: "XKit", package: "xtool")
```
