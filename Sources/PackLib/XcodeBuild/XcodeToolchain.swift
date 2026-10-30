import Foundation
import Subprocess
import XUtils
import Superutils

/// The tools and SDK used to build Xcode projects for iOS devices.
public struct XcodeToolchain: Sendable {
    /// The `clang` compiler driver, used for compiling and linking.
    public var clang: URL
    /// The `swiftc` compiler driver.
    public var swiftc: URL
    /// An explicit linker (ld64.lld) to pass via `--ld-path`, or nil to use the driver's default.
    public var linker: URL?
    /// A Darwin-compatible `libtool` for creating static libraries.
    public var libtool: URL
    /// The Developer directory (`DEVELOPER_DIR`).
    public var developerDir: URL
    /// The iPhoneOS SDK (`SDKROOT`).
    public var sdk: URL
    /// The SDK version, e.g. `26.0`.
    public var sdkVersion: String
    /// The Swift resource directory to pass to swiftc, if non-default.
    public var swiftResourceDir: URL?

    public init(
        clang: URL,
        swiftc: URL,
        linker: URL?,
        libtool: URL,
        developerDir: URL,
        sdk: URL,
        sdkVersion: String,
        swiftResourceDir: URL?
    ) {
        self.clang = clang
        self.swiftc = swiftc
        self.linker = linker
        self.libtool = libtool
        self.developerDir = developerDir
        self.sdk = sdk
        self.sdkVersion = sdkVersion
        self.swiftResourceDir = swiftResourceDir
    }

    /// The arguments that make `libtool` write a static library of the objects listed in `fileList`.
    ///
    /// On Linux the Darwin SDK's toolset has no `libtool`, so `libtool` may be LLVM's `llvm-ar`, which
    /// writes the same Darwin archive from a response file.
    public func archiveArguments(output: URL, fileList: URL) -> [String] {
        libtool.lastPathComponent.hasPrefix("llvm-ar")
            ? ["rcs", "--format=darwin", output.path, "@\(fileList.path)"]
            : ["-static", "-o", output.path, "-filelist", fileList.path]
    }

    public var toolchainDir: URL {
        developerDir.appending(path: "Toolchains/XcodeDefault.xctoolchain")
    }

    public var platformDir: URL {
        developerDir.appending(path: "Platforms/iPhoneOS.platform")
    }

    /// Directories containing the Swift runtime/compatibility libraries for iOS.
    public var swiftLibraryDirs: [URL] {
        [
            sdk.appending(path: "usr/lib/swift"),
            (swiftResourceDir ?? toolchainDir.appending(path: "usr/lib/swift")).appending(path: "iphoneos"),
        ]
    }

    /// The compiler-rt builtins archive for iOS, if available (needed for e.g. `@available`).
    public var compilerRTLibrary: URL? {
        let clangLib = toolchainDir.appending(path: "usr/lib/clang")
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: clangLib.path) else { return nil }
        for version in versions.sorted().reversed() {
            let candidate = clangLib.appending(path: "\(version)/lib/darwin/libclang_rt.ios.a")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    static func sdkVersion(of sdk: URL) -> String {
        let settings = sdk.appending(path: "SDKSettings.plist")
        if let data = try? Data(contentsOf: settings),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let version = plist["Version"] as? String {
            return version
        }
        // fall back to parsing the name, e.g. iPhoneOS26.0.sdk
        let name = sdk.deletingPathExtension().lastPathComponent
        return String(name.drop { !$0.isNumber })
    }

    /// Locates the toolchain for the current host.
    public static func current() async throws -> XcodeToolchain {
        #if os(macOS)
        func xcrun(_ args: [String]) async throws -> String {
            try await Subprocess.run(
                .path("/usr/bin/xcrun"),
                arguments: .init(args),
                output: .string(limit: .max)
            )
            .checkSuccess()
            .standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let sdk = URL(fileURLWithPath: try await xcrun(["--sdk", "iphoneos", "--show-sdk-path"]))
        let developerDir = try await Subprocess.run(
            .path("/usr/bin/xcode-select"),
            arguments: ["-p"],
            output: .string(limit: .max)
        ).checkSuccess().standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return XcodeToolchain(
            clang: URL(fileURLWithPath: try await xcrun(["--sdk", "iphoneos", "-f", "clang"])),
            swiftc: URL(fileURLWithPath: try await xcrun(["--sdk", "iphoneos", "-f", "swiftc"])),
            linker: nil,
            libtool: URL(fileURLWithPath: try await xcrun(["--sdk", "iphoneos", "-f", "libtool"])),
            developerDir: URL(fileURLWithPath: developerDir),
            sdk: sdk,
            sdkVersion: sdkVersion(of: sdk),
            swiftResourceDir: nil
        )
        #else
        let darwinSDK = try DarwinSDK.current()
            .orThrow(StringError("No Darwin SDK configured. Please run `xtool setup`."))
        let developerDir = darwinSDK.bundle.appending(path: "Developer")
        let sdksDir = developerDir.appending(path: "Platforms/iPhoneOS.platform/Developer/SDKs")
        let sdkName = try FileManager.default.contentsOfDirectory(atPath: sdksDir.path)
            .filter { $0.hasPrefix("iPhoneOS") && $0.hasSuffix(".sdk") }
            // prefer versioned SDK names (iPhoneOS26.0.sdk) over the unversioned symlink
            .max { $0.count < $1.count }
            .orThrow(StringError("Could not find the iPhoneOS SDK in '\(sdksDir.path)'"))
        let sdk = sdksDir.appending(path: sdkName)
        let toolsetBin = darwinSDK.bundle.appending(path: "toolset/bin")
        let swiftc = try await BuildSettings.swiftcURL()
        let clang = try await ToolRegistry.locate("clang")
        let toolsetLibtool = toolsetBin.appending(path: "libtool")
        let libtool = FileManager.default.isExecutableFile(atPath: toolsetLibtool.path)
            ? toolsetLibtool
            : try await ToolRegistry.locate("llvm-ar")
        return XcodeToolchain(
            clang: clang,
            swiftc: URL(fileURLWithPath: swiftc.string),
            linker: toolsetBin.appending(path: "ld64.lld"),
            libtool: libtool,
            developerDir: developerDir,
            sdk: sdk,
            sdkVersion: sdkVersion(of: sdk),
            swiftResourceDir: developerDir.appending(path: "Toolchains/XcodeDefault.xctoolchain/usr/lib/swift")
        )
        #endif
    }
}
