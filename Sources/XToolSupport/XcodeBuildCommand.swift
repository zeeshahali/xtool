import XCLIUtils
import Foundation
import ArgumentParser
import PackLib
import XcodeProjects
import XKit
import Dependencies
import XUtils
import Subprocess

struct XcodeBuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xcodebuild",
        abstract: "Build an Xcode project (.xcodeproj) into an iOS app or IPA",
        discussion: """
        Builds an existing Xcode project, such as one exported by Unity, for iOS \
        devices without needing Xcode. Works on Linux, WSL, and macOS.

        Supports build settings and .xcconfig files, target dependencies, and the \
        Sources, Headers, Frameworks, Resources, Copy Files, and Run Script build \
        phases. Storyboards, XIBs, and asset catalog entries other than the app icon \
        require Apple's macOS-only compilers and are skipped with a warning.

        Build settings may be overridden xcodebuild-style, e.g.
            xtool xcodebuild --ipa PRODUCT_BUNDLE_IDENTIFIER=com.example.game
        """
    )

    @Option(
        name: [.long, .customLong("project", withSingleDash: true)],
        help: "Path to the .xcodeproj to build. Defaults to the only .xcodeproj in the current directory.",
        completion: .directory
    ) var project: String?

    @Option(
        name: [.long, .customLong("target", withSingleDash: true)],
        help: "Target to build. Defaults to the first application target."
    ) var target: String?

    @Option(
        name: [.long, .customShort("c"), .customLong("configuration", withSingleDash: true)],
        help: "Build configuration, e.g. Debug or Release. Defaults to the project's default."
    ) var configuration: String?

    @Option(
        name: .long,
        help: "Directory for build products and intermediates. Defaults to <project dir>/build.",
        completion: .directory
    ) var buildDir: String?

    @Option(
        name: [.short, .long],
        help: "Number of parallel compile jobs."
    ) var jobs: Int = ProcessInfo.processInfo.activeProcessorCount

    @Flag(help: "Run 'Run Script' build phases (skipped by default since they often call macOS-only tools).")
    var runScripts = false

    @Flag(name: .shortAndLong, help: "Codesign the built app with your Apple ID (requires `xtool auth`).")
    var sign = false

    @Flag(name: .shortAndLong, help: "Output a .ipa file instead of a .app")
    var ipa = false

    @Option(
        name: .shortAndLong,
        help: "Where to write the final .app or .ipa. Defaults to the build directory.",
        completion: .file()
    ) var output: String?

    @Flag(name: .shortAndLong, help: "Print every command that is executed.")
    var verbose = false

    @Flag(help: "List the project's targets and configurations, then exit.")
    var list = false

    @Argument(help: "Build setting overrides in the form KEY=VALUE.")
    var settings: [String] = []

    func validate() throws {
        for setting in settings where !setting.contains("=") {
            throw ValidationError("Expected a build setting override of the form KEY=VALUE, got '\(setting)'")
        }
        if jobs < 1 {
            throw ValidationError("--jobs must be at least 1")
        }
    }

    func run() async throws {
        let projectURL = try locateProject()
        let model = try XcodeBuildModel(contentsOf: projectURL)

        if list {
            printTargets(model)
            return
        }

        let signingAuthToken: AuthToken?
        if sign {
            guard let token = try AuthToken.savedIfPresent() else {
                throw Console.Error("`xcodebuild --sign` requires logging in with `xtool auth`")
            }
            signingAuthToken = token
        } else {
            signingAuthToken = nil
        }

        try await EnsureSDKOperation(quiet: true).run()
        let toolchain = try await XcodeToolchain.current()

        var overrides: [String: String] = [:]
        for setting in settings {
            let parts = setting.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            overrides[String(parts[0])] = String(parts[1])
        }

        let buildDirURL = buildDir.map { URL(fileURLWithPath: $0) }
            ?? model.url.deletingLastPathComponent().appending(path: "build")
        let builder = XcodeProjectBuilder(
            model: model,
            toolchain: toolchain,
            options: .init(
                target: target,
                configuration: configuration,
                buildDir: buildDirURL.standardizedFileURL,
                jobs: jobs,
                runScripts: runScripts,
                overrides: overrides,
                verbose: verbose
            ),
            log: { d.out.print($0) }
        )

        d.out.print("Building \(projectURL.lastPathComponent) with iPhoneOS \(toolchain.sdkVersion) SDK")
        let product: XcodeProjectBuilder.Product
        do {
            product = try await builder.build()
        } catch let error as XcodeProjectBuilder.Errors {
            throw Console.Error("\(error)")
        }

        // work on a copy so that incremental builds aren't affected by signing
        let staging = try TemporaryDirectory(name: "xcodebuild-output")
        let app = staging.url.appending(path: product.url.lastPathComponent)
        try FileManager.default.copyItem(at: product.url, to: app)

        if let entitlementsURL = product.entitlements {
            let entitlements = try Data(contentsOf: entitlementsURL)
            d.out.print("Applying entitlements...")
            try await d.signer.sign(
                app: app,
                identity: .adhoc,
                entitlementMapping: [app: entitlements],
                deep: true,
                progress: { _ in }
            )
        }

        if let signingAuthToken {
            // the installer holds its delegate weakly; keep it alive, or the revocation prompt is
            // never shown and silently answers no
            let signDelegate = XToolInstallerDelegate()
            let installer = IntegratedInstaller(
                auth: signingAuthToken.authData(),
                delegate: signDelegate
            )
            do {
                defer { d.out.print() }
                try await installer.signInPlace(app: app)
                withExtendedLifetime(signDelegate) {}
            } catch let error as CancellationError {
                throw error
            } catch {
                d.out.print("Error: \(error)")
                throw ExitCode.failure
            }
        }

        let finalURL: URL
        let defaultDirectory = buildDirURL
        if ipa {
            finalURL = output.map { URL(fileURLWithPath: $0) }
                ?? defaultDirectory.appending(path: app.deletingPathExtension().lastPathComponent + ".ipa")
            try await IPAPackager.package(app: app, to: finalURL)
        } else {
            finalURL = output.map { URL(fileURLWithPath: $0) }
                ?? defaultDirectory.appending(path: app.lastPathComponent)
            try? FileManager.default.removeItem(at: finalURL)
            try FileManager.default.moveItem(at: app, to: finalURL)
        }

        d.out.print("Wrote to \(finalURL.path)")
    }

    private func locateProject() throws -> URL {
        if let project {
            var url = URL(fileURLWithPath: project)
            if url.pathExtension != "xcodeproj" {
                // allow pointing at the directory that contains the project
                url = try findProject(in: url)
            }
            return url
        }
        return try findProject(in: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    }

    private func findProject(in directory: URL) throws -> URL {
        let projects = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.hasSuffix(".xcodeproj") }
            .sorted() ?? []
        switch projects.count {
        case 0:
            throw Console.Error("Could not find an .xcodeproj in '\(directory.path)'. Pass one with --project.")
        case 1:
            return directory.appending(path: projects[0])
        default:
            // Unity exports a single Unity-iPhone.xcodeproj; prefer it if present.
            if projects.contains("Unity-iPhone.xcodeproj") {
                return directory.appending(path: "Unity-iPhone.xcodeproj")
            }
            throw Console.Error("""
            Found multiple projects in '\(directory.path)' (\(projects.joined(separator: ", "))). \
            Pass one with --project.
            """)
        }
    }

    private func printTargets(_ model: XcodeBuildModel) {
        d.out.print("Information about project \"\(model.name)\":")
        d.out.print("    Targets:")
        for target in model.targets {
            d.out.print("        \(target.name) (\(target.productType))")
        }
        d.out.print("    Build Configurations:")
        for config in model.configurations {
            d.out.print("        \(config.name)")
        }
        if let defaultConfig = model.defaultConfigurationName {
            d.out.print("    Default configuration: \(defaultConfig)")
        }
    }
}

enum IPAPackager {
    /// Zips `app` into an IPA (`Payload/<app>`) at `destination`, consuming the app.
    ///
    /// Unlike the `zipCompressor` used to install apps, which stores files uncompressed for speed,
    /// this deflates them: an IPA is meant to be shipped, and a stored one is several times larger.
    static func package(app: URL, to destination: URL) async throws {
        let tmpDir = try TemporaryDirectory(name: "Payload")
        let payloadDir = tmpDir.url
        try FileManager.default.moveItem(at: app, to: payloadDir.appendingPathComponent(app.lastPathComponent))
        let ipaURL = payloadDir.deletingLastPathComponent().appendingPathComponent("app.ipa")
        d.out.print("Packaging...")
        try await Subprocess.run(
            .name("zip"),
            arguments: ["-yqr", ipaURL.path, payloadDir.lastPathComponent],
            workingDirectory: FilePath(payloadDir.deletingLastPathComponent()),
            output: .discarded,
        ).checkSuccess()
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: ipaURL, to: destination)
    }
}
