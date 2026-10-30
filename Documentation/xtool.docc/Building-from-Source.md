# Building from Source

Build and install `xtool` yourself on Linux or Windows (via WSL).

## Overview

The prebuilt `xtool.AppImage` in <doc:Installation-Linux> is the easiest way to get xtool. Build from source instead when you need changes that aren't in a release yet, such as `xtool xcodebuild` for Unity projects (see <doc:Xcode-Projects>).

On Windows, everything below runs inside WSL. Native Windows isn't supported.

## Prerequisites

### WSL 2 (Windows only)

Install [WSL 2](https://learn.microsoft.com/en-us/windows/wsl/install) with an Ubuntu distribution, then follow the Ubuntu/Debian steps in this guide from a WSL terminal:

```powershell
wsl --install -d Ubuntu-24.04
```

Keep your projects inside the WSL file system (for example `~/projects`), not under `/mnt/c`. Builds there are much faster.

You only need USB passthrough ([usbipd-win](https://learn.microsoft.com/en-us/windows/wsl/connect-usb)) to install apps on a connected iPhone. Building IPAs doesn't need it.

### Swift 6.4

xtool needs a Swift **6.4.x** toolchain. Older versions fail to compile it. Install it with [swiftly](https://www.swift.org/install/linux/):

```bash
curl -O https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz
tar zxf swiftly-$(uname -m).tar.gz
./swiftly init --quiet-shell-followup --skip-install
. ~/.local/share/swiftly/env.sh
swiftly install 6.4.1 --use
swift --version
# Swift version 6.4.1 (swift-6.4.1-RELEASE)
```

swiftly adds itself to your login profile. If `swift` isn't found in a new terminal, also add `. ~/.local/share/swiftly/env.sh` to `~/.bashrc`. xtool runs `swiftc` while building, so it must be on your `PATH`.

> Note: Arch Linux and other distros swiftly doesn't support:
>
> - Run `swiftly init` with `--platform ubuntu24.04`.
> - Install `libxml2-legacy` (`sudo pacman -S libxml2-legacy`), which provides the `libxml2.so.2` the toolchain links against.
> - The toolchain looks for `libncurses.so.6`, which Arch names `libncursesw.so.6`. Link it inside the toolchain, without touching system files:
>
>   ```bash
>   ln -s /usr/lib/libncursesw.so.6 \
>     ~/.local/share/swiftly/toolchains/6.4.1/usr/lib/swift/linux/libncurses.so.6
>   ```

### Build dependencies

**Ubuntu/Debian (including WSL):**

```bash
sudo apt-get install build-essential git autoconf automake libtool-bin pkg-config \
  libssl-dev libcurl4-openssl-dev libxml2-dev zlib1g-dev liblzma-dev zip unzip usbmuxd
```

**Arch Linux:**

```bash
sudo pacman -S --needed base-devel git autoconf automake libtool pkgconf \
  openssl curl libxml2 zlib xz zip unzip usbmuxd
```

`zip` and `unzip` are used at runtime to package and read IPAs. `usbmuxd` is only needed to talk to a connected device.

### libimobiledevice

xtool links against the libimobiledevice libraries. It needs at least these versions:

| Library | Minimum version |
|---|---|
| libplist | 2.6.0 |
| libimobiledevice-glue | 1.3.1 |
| libusbmuxd | 2.1.0 |
| libtatsu | 1.0.4 |
| libimobiledevice | 1.4.0 (or `master`) |

**Arch Linux** and other rolling distros already package these versions:

```bash
sudo pacman -S --needed libplist libimobiledevice-glue libusbmuxd libtatsu libimobiledevice
```

**Ubuntu/Debian** packages are older, so build them from source, in this order. These are the same tags the [Dockerfile](https://github.com/zeeshahali/xtool/blob/main/Dockerfile) uses:

```bash
build() { # repo, tag, extra configure flags
  git clone --depth 1 -b "$2" "https://github.com/libimobiledevice/$1.git"
  (cd "$1" && ./autogen.sh --prefix /usr "${@:3}" && make && sudo make install)
}
build libplist 2.6.0 --without-cython
build libimobiledevice-glue 1.3.1
build libusbmuxd 2.1.0
build libtatsu 1.0.4
build libimobiledevice master --without-cython
sudo ldconfig
```

Don't build these over newer distro packages (as on Arch). That overwrites files your package manager owns.

## Build and install

```bash
git clone https://github.com/zeeshahali/xtool
cd xtool
git checkout claude/happy-bell-asigux  # has `xtool xcodebuild`, until it's merged
swift build -c release --product xtool
sudo install -m755 .build/release/xtool /usr/local/bin/xtool
xtool --help
```

The first build downloads dependencies and takes several minutes. Later builds are incremental.

The installed binary loads Swift's runtime libraries from the toolchain it was built with (for example `~/.local/share/swiftly/toolchains/6.4.1`). Keep that toolchain installed, or rebuild xtool after changing toolchains.

## Set up the iOS SDK

Download **Xcode 27.x** from <https://developer.apple.com/download/all/?q=Xcode> in your browser. It needs an Apple ID sign-in, so `curl` won't work. Then:

```bash
xtool setup
```

This signs you in to Apple (needed for signed builds, see <doc:Xcode-Projects>) and asks for the path to the `.xip`. If you only need unsigned builds, you can skip the sign-in and install just the SDK:

```bash
xtool sdk install ~/Downloads/Xcode_27.2.xip
xtool sdk status
# Darwin SDK is installed
```

## Troubleshooting

- **`error while loading shared libraries: libncurses.so.6` or `libxml2.so.2`** when running `swift`: see the Arch Linux note under Swift 6.4 above.
- **`Could not find executable 'swiftc' in PATH`** from `xtool sdk` or `xtool xcodebuild`: load swiftly's environment in that shell (`. ~/.local/share/swiftly/env.sh`).
- **Linting**: to run `make lint` on Linux, point SwiftLint at the toolchain's SourceKit:
  `LINUX_SOURCEKIT_LIB_PATH=~/.local/share/swiftly/toolchains/6.4.1/usr/lib make lint`
