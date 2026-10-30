import Foundation
import Subprocess
import XUtils
import Superutils
import XcodeProjects

/// Builds an Xcode project (`.xcodeproj`) for iOS devices without Xcode.
///
/// This understands the subset of the Xcode build system that's commonly used
/// by generated projects (such as those exported by Unity): build settings and
/// xcconfigs, target dependencies, and the sources, frameworks, headers,
/// resources, copy-files, and run-script build phases.
public struct XcodeProjectBuilder: Sendable {
    public typealias Logger = @Sendable (String) -> Void

    public struct Options: Sendable {
        /// The target to build. Defaults to the first application target.
        public var target: String?
        /// The build configuration. Defaults to the project's default configuration.
        public var configuration: String?
        /// Where to place build products and intermediates.
        public var buildDir: URL
        /// Maximum number of parallel compile jobs.
        public var jobs: Int
        /// Whether to run "Run Script" build phases.
        public var runScripts: Bool
        /// Build setting overrides, like `xcodebuild KEY=VALUE`.
        public var overrides: [String: String]
        /// Print every command that is executed.
        public var verbose: Bool

        public init(
            target: String? = nil,
            configuration: String? = nil,
            buildDir: URL,
            jobs: Int = ProcessInfo.processInfo.activeProcessorCount,
            runScripts: Bool = false,
            overrides: [String: String] = [:],
            verbose: Bool = false
        ) {
            self.target = target
            self.configuration = configuration
            self.buildDir = buildDir
            self.jobs = max(1, jobs)
            self.runScripts = runScripts
            self.overrides = overrides
            self.verbose = verbose
        }
    }

    public struct Product: Sendable {
        public var targetName: String
        /// The built product (e.g. the `.app` bundle).
        public var url: URL
        /// The entitlements file specified by `CODE_SIGN_ENTITLEMENTS`, if any.
        public var entitlements: URL?
    }

    public enum Errors: Error, CustomStringConvertible {
        case noTarget(available: [String])
        case unknownTarget(String, available: [String])
        case dependencyCycle(String)
        case commandFailed(command: String, output: String)
        case missingFile(String)

        public var description: String {
            switch self {
            case .noTarget(let available):
                "Could not find an application target. Pass one with --target. Available: \(available.joined(separator: ", "))"
            case .unknownTarget(let name, let available):
                "Unknown target '\(name)'. Available: \(available.joined(separator: ", "))"
            case .dependencyCycle(let name):
                "Dependency cycle detected involving target '\(name)'"
            case .commandFailed(let command, let output):
                "Command failed:\n\(command)\n\(output)"
            case .missingFile(let path):
                "File not found: \(path)"
            }
        }
    }

    public let model: XcodeBuildModel
    public let toolchain: XcodeToolchain
    public let options: Options
    private let log: Logger

    public init(
        model: XcodeBuildModel,
        toolchain: XcodeToolchain,
        options: Options,
        log: @escaping Logger
    ) {
        self.model = model
        self.toolchain = toolchain
        self.options = options
        self.log = log
    }

    public var configurationName: String {
        options.configuration ?? model.defaultConfigurationName ?? "Release"
    }

    /// The target that will be built.
    public func mainTarget() throws -> XcodeBuildModel.Target {
        let available = model.targets.map(\.name)
        if let name = options.target {
            return try model.target(named: name).orThrow(Errors.unknownTarget(name, available: available))
        }
        return try model.targets
            .first { $0.productType == ProductType.application }
            .orThrow(Errors.noTarget(available: available))
    }

    /// Builds the main target and its dependencies, returning the main product.
    public func build() async throws -> Product {
        let main = try mainTarget()
        let order = try buildOrder(for: main)
        log("Building \(order.map(\.name).joined(separator: " -> ")) [\(configurationName)]")
        var mainProduct: Product?
        for target in order {
            let settings = try settings(for: target)
            let builder = TargetBuilder(
                model: model,
                target: target,
                settings: settings,
                toolchain: toolchain,
                options: options,
                runner: CommandRunner(verbose: options.verbose, log: log),
                log: log
            )
            let product = try await builder.build()
            if target.name == main.name { mainProduct = product }
        }
        return try mainProduct.orThrow(Errors.unknownTarget(main.name, available: []))
    }

    /// Returns `target` and its transitive dependencies in build order.
    public func buildOrder(for target: XcodeBuildModel.Target) throws -> [XcodeBuildModel.Target] {
        var order: [XcodeBuildModel.Target] = []
        var visiting: Set<String> = []
        var visited: Set<String> = []

        // products of other targets, by file name, to discover implicit dependencies
        var productOwners: [String: String] = [:]
        for candidate in model.targets {
            if let name = try? settings(for: candidate).string("FULL_PRODUCT_NAME"), !name.isEmpty {
                productOwners[name] = candidate.name
            }
        }

        func visit(_ target: XcodeBuildModel.Target) throws {
            if visited.contains(target.name) { return }
            guard visiting.insert(target.name).inserted else {
                throw Errors.dependencyCycle(target.name)
            }
            var dependencies = target.dependencies
            for phase in target.buildPhases {
                let files: [XcodeBuildModel.BuildFile]
                switch phase {
                case .frameworks(let list): files = list
                case .copyFiles(let copy): files = copy.files
                default: continue
                }
                for file in files where file.file.location.tree == XcodeBuildModel.Location.builtProductsDir {
                    if let owner = productOwners[file.file.location.lastPathComponent], owner != target.name {
                        dependencies.append(owner)
                    }
                }
            }
            for name in dependencies {
                if let dependency = model.target(named: name) {
                    try visit(dependency)
                }
            }
            visiting.remove(target.name)
            visited.insert(target.name)
            order.append(target)
        }

        try visit(target)
        return order
    }

    /// Removes flags that select Apple's linker variants, which lld doesn't understand.
    public static func filterLinkerFlags(_ args: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if ["-ld64", "-ld_classic", "-Wl,-ld_classic", "-Wl,-ld64", "-ld_new", "-Wl,-ld_new",
                "-Wl,-no_compact_unwind", "-fembed-bitcode", "-fembed-bitcode-marker",
                "-Wl,-bitcode_bundle", ].contains(arg) {
                index += 1
                continue
            }
            if arg == "-Xlinker", index + 1 < args.count,
               ["-ld_classic", "-ld64", "-ld_new", "-bitcode_bundle"].contains(args[index + 1]) {
                index += 2
                continue
            }
            result.append(arg)
            index += 1
        }
        return result
    }

    /// The linker flags that strip a linked product the way an Xcode archive does.
    ///
    /// Xcode strips installed products (`STRIP_INSTALLED_PRODUCT`) only when `DEPLOYMENT_POSTPROCESSING`
    /// is on, as it is for an archive. xtool builds products to install and ship, so that defaults on here.
    /// ld64.lld can't remove global symbols, so `STRIP_STYLE = all` strips like `non-global`.
    public static func stripLinkerFlags(_ settings: XcodeSettings) -> [String] {
        guard settings.bool("DEPLOYMENT_POSTPROCESSING", default: true),
              settings.bool("STRIP_INSTALLED_PRODUCT", default: true)
        else { return [] }
        let debugInfo = ["-Xlinker", "-S"]
        return settings.string("STRIP_STYLE") == "debugging" ? debugInfo : debugInfo + ["-Xlinker", "-x"]
    }

    /// Computes the build settings for a target.
    public func settings(for target: XcodeBuildModel.Target) throws -> XcodeSettings {
        let projectConfig = model.configuration(named: configurationName)
            ?? model.defaultConfigurationName.flatMap(model.configuration(named:))
            ?? model.configurations.first
        let targetConfig = target.configuration(named: configurationName)
            ?? target.defaultConfigurationName.flatMap(target.configuration(named:))
            ?? target.configurations.first
        let configName = targetConfig?.name ?? configurationName

        let sdkName = "iphoneos\(toolchain.sdkVersion)"
        let conditions = XcodeSettings.Conditions(sdk: sdkName, arch: "arm64", config: configName)

        var settings = XcodeSettings()
        settings.push(defaults(for: target, configuration: configName, sdkName: sdkName))

        func xcconfig(_ location: XcodeBuildModel.Location?) throws -> XcodeSettings.Layer {
            guard let location else { return [:] }
            let url: URL = switch location.tree {
            case XcodeBuildModel.Location.absolute: URL(fileURLWithPath: location.path)
            default: model.sourceRoot.appending(path: location.path)
            }
            return try XcodeSettings.layer(xcconfig: url, conditions: conditions)
        }

        settings.push(try xcconfig(projectConfig?.baseConfiguration))
        settings.push(XcodeSettings.layer(from: projectConfig?.settings ?? [:], conditions: conditions))
        settings.push(try xcconfig(targetConfig?.baseConfiguration))
        settings.push(XcodeSettings.layer(from: targetConfig?.settings ?? [:], conditions: conditions))

        // values that must reflect how we're actually building
        var forced: XcodeSettings.Layer = [
            "SDKROOT": toolchain.sdk.path,
            "SDK_DIR": toolchain.sdk.path,
            "SDK_NAME": sdkName,
            "SDK_VERSION": toolchain.sdkVersion,
            "PLATFORM_NAME": "iphoneos",
            "EFFECTIVE_PLATFORM_NAME": "-iphoneos",
            "CURRENT_ARCH": "arm64",
            "arch": "arm64",
            "CONFIGURATION": configName,
        ]
        forced.merge(options.overrides) { $1 }
        settings.push(forced)
        return settings
    }

    private func defaults(
        for target: XcodeBuildModel.Target,
        configuration: String,
        sdkName: String
    ) -> XcodeSettings.Layer {
        let type = target.productType
        let (wrapperExtension, executablePrefix, executableExtension) = ProductType.naming(for: type)
        let isWrapper = !wrapperExtension.isEmpty
        let buildDir = options.buildDir.appending(path: "Build")
        let isDebug = configuration.lowercased().contains("debug")
        var layer: XcodeSettings.Layer = [
            "ACTION": "build",
            "PROJECT_NAME": model.name,
            "PROJECT": model.name,
            "PROJECT_DIR": model.sourceRoot.path,
            "PROJECT_FILE_PATH": model.url.path,
            "SRCROOT": model.sourceRoot.path,
            "SOURCE_ROOT": model.sourceRoot.path,
            "TARGET_NAME": target.name,
            "TARGETNAME": target.name,
            "PRODUCT_NAME": target.productName ?? target.name,
            "PRODUCT_TYPE": type,
            "PRODUCT_MODULE_NAME": "$(PRODUCT_NAME:c99extidentifier)",
            "EXECUTABLE_PREFIX": executablePrefix,
            "EXECUTABLE_SUFFIX": executableExtension.isEmpty ? "" : ".\(executableExtension)",
            "EXECUTABLE_EXTENSION": executableExtension,
            "EXECUTABLE_NAME": "$(EXECUTABLE_PREFIX)$(PRODUCT_NAME)$(EXECUTABLE_SUFFIX)",
            "WRAPPER_EXTENSION": wrapperExtension,
            "WRAPPER_SUFFIX": isWrapper ? ".\(wrapperExtension)" : "",
            "WRAPPER_NAME": isWrapper ? "$(PRODUCT_NAME)$(WRAPPER_SUFFIX)" : "",
            "FULL_PRODUCT_NAME": isWrapper ? "$(WRAPPER_NAME)" : "$(EXECUTABLE_NAME)",
            "CONTENTS_FOLDER_PATH": isWrapper ? "$(WRAPPER_NAME)" : "",
            "EXECUTABLE_FOLDER_PATH": "$(CONTENTS_FOLDER_PATH)",
            "EXECUTABLE_PATH": isWrapper ? "$(EXECUTABLE_FOLDER_PATH)/$(EXECUTABLE_NAME)" : "$(EXECUTABLE_NAME)",
            "UNLOCALIZED_RESOURCES_FOLDER_PATH": "$(CONTENTS_FOLDER_PATH)",
            "FRAMEWORKS_FOLDER_PATH": "$(CONTENTS_FOLDER_PATH)/Frameworks",
            "PLUGINS_FOLDER_PATH": "$(CONTENTS_FOLDER_PATH)/PlugIns",
            "PUBLIC_HEADERS_FOLDER_PATH": isWrapper ? "$(CONTENTS_FOLDER_PATH)/Headers" : "include/$(PRODUCT_NAME)",
            "PRIVATE_HEADERS_FOLDER_PATH": isWrapper ? "$(CONTENTS_FOLDER_PATH)/PrivateHeaders" : "include/$(PRODUCT_NAME)",
            "INFOPLIST_PATH": "$(CONTENTS_FOLDER_PATH)/Info.plist",
            "SYMROOT": buildDir.appending(path: "Products").path,
            "BUILD_DIR": "$(SYMROOT)",
            "BUILD_ROOT": "$(SYMROOT)",
            "CONFIGURATION_BUILD_DIR": "$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)",
            "BUILT_PRODUCTS_DIR": "$(CONFIGURATION_BUILD_DIR)",
            "TARGET_BUILD_DIR": "$(CONFIGURATION_BUILD_DIR)",
            "OBJROOT": buildDir.appending(path: "Intermediates.noindex").path,
            "PROJECT_TEMP_DIR": "$(OBJROOT)/$(PROJECT_NAME).build",
            "CONFIGURATION_TEMP_DIR": "$(PROJECT_TEMP_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)",
            "TARGET_TEMP_DIR": "$(CONFIGURATION_TEMP_DIR)/$(TARGET_NAME).build",
            "TEMP_DIR": "$(TARGET_TEMP_DIR)",
            "DERIVED_FILE_DIR": "$(TARGET_TEMP_DIR)/DerivedSources",
            "DERIVED_FILES_DIR": "$(DERIVED_FILE_DIR)",
            "DERIVED_SOURCES_DIR": "$(DERIVED_FILE_DIR)",
            "OBJECT_FILE_DIR": "$(TARGET_TEMP_DIR)/Objects-normal",
            "OBJECT_FILE_DIR_normal": "$(OBJECT_FILE_DIR)",
            "MODULE_CACHE_DIR": options.buildDir.appending(path: "ModuleCache.noindex").path,
            "DEVELOPER_DIR": toolchain.developerDir.path,
            "TOOLCHAIN_DIR": toolchain.toolchainDir.path,
            "DT_TOOLCHAIN_DIR": toolchain.toolchainDir.path,
            "PLATFORM_DIR": toolchain.platformDir.path,
            "PLATFORM_DEVELOPER_SDK_DIR": "$(PLATFORM_DIR)/Developer/SDKs",
            "DEVELOPER_FRAMEWORKS_DIR": "$(DEVELOPER_DIR)/Library/Frameworks",
            "PLATFORM_DISPLAY_NAME": "iOS",
            "ARCHS_STANDARD": "arm64",
            "ARCHS_STANDARD_64_BIT": "arm64",
            "ARCHS": "$(ARCHS_STANDARD)",
            "NATIVE_ARCH": "arm64",
            "VALID_ARCHS": "arm64 arm64e",
            "IPHONEOS_DEPLOYMENT_TARGET": "15.0",
            "TARGETED_DEVICE_FAMILY": "1",
            "GCC_OPTIMIZATION_LEVEL": isDebug ? "0" : "s",
            "SWIFT_OPTIMIZATION_LEVEL": isDebug ? "-Onone" : "-O",
            "SWIFT_COMPILATION_MODE": "wholemodule",
            "CLANG_CXX_LIBRARY": "libc++",
            "GCC_C_LANGUAGE_STANDARD": "compiler-default",
            "CLANG_CXX_LANGUAGE_STANDARD": "compiler-default",
            "OTHER_CPLUSPLUSFLAGS": "$(OTHER_CFLAGS)",
            "USE_HEADERMAP": "YES",
            "DEAD_CODE_STRIPPING": "YES",
            "GCC_ENABLE_CPP_EXCEPTIONS": "YES",
            "GCC_ENABLE_CPP_RTTI": "YES",
            "GCC_ENABLE_OBJC_EXCEPTIONS": "YES",
            "DEBUG_INFORMATION_FORMAT": "dwarf",
            "GCC_GENERATE_DEBUGGING_SYMBOLS": "YES",
            "DYLIB_INSTALL_NAME_BASE": "@rpath",
            "LD_DYLIB_INSTALL_NAME": "$(DYLIB_INSTALL_NAME_BASE:standardizepath)/$(EXECUTABLE_PATH)",
            "DEFINES_MODULE": "NO",
            "REMOVE_HEADERS_FROM_EMBEDDED_BUNDLES": "YES",
            "ASSETCATALOG_COMPILER_APPICON_NAME": "",
            "INFOPLIST_EXPAND_BUILD_SETTINGS": "YES",
            "SWIFT_VERSION": "5",
            "CODE_SIGNING_ALLOWED": "YES",
            "SHELL": "/bin/sh",
            "USER": ProcessInfo.processInfo.environment["USER"] ?? "user",
            "HOME": ProcessInfo.processInfo.environment["HOME"] ?? "/",
        ]
        if type == ProductType.appExtension {
            layer["APPLICATION_EXTENSION_API_ONLY"] = "YES"
        }
        return layer
    }
}

enum ProductType {
    static let application = "com.apple.product-type.application"
    static let framework = "com.apple.product-type.framework"
    static let staticFramework = "com.apple.product-type.framework.static"
    static let dynamicLibrary = "com.apple.product-type.library.dynamic"
    static let staticLibrary = "com.apple.product-type.library.static"
    static let bundle = "com.apple.product-type.bundle"
    static let appExtension = "com.apple.product-type.app-extension"
    static let messagesExtension = "com.apple.product-type.app-extension.messages"
    static let watchApp = "com.apple.product-type.application.watchapp2"
    static let tool = "com.apple.product-type.tool"

    /// (wrapper extension, executable prefix, executable extension)
    static func naming(for type: String) -> (String, String, String) {
        switch type {
        case application, watchApp: ("app", "", "")
        case framework, staticFramework: ("framework", "", "")
        case appExtension, messagesExtension: ("appex", "", "")
        case bundle: ("bundle", "", "")
        case dynamicLibrary: ("", "lib", "dylib")
        case staticLibrary: ("", "lib", "a")
        default:
            if type.hasPrefix("com.apple.product-type.app-extension") {
                ("appex", "", "")
            } else if type.hasPrefix("com.apple.product-type.bundle") {
                ("xctest", "", "")
            } else {
                ("", "", "")
            }
        }
    }
}

// MARK: - Command running

struct CommandRunner: Sendable {
    var verbose: Bool
    var log: XcodeProjectBuilder.Logger

    @discardableResult
    func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil,
        printOutput: Bool = false
    ) async throws -> String {
        let commandLine = ([executable.path] + arguments).map(Self.shellQuote).joined(separator: " ")
        if verbose { log(commandLine) }
        var env: Environment = .inherit
        if let environment {
            env = .inherit.updating(Dictionary(uniqueKeysWithValues: environment.compactMap { key, value in
                Environment.Key(rawValue: key).map { ($0, Optional(value)) }
            }))
        }
        let result = try await Subprocess.run(
            .path(FilePath(executable.path)),
            arguments: Arguments(arguments),
            environment: env,
            workingDirectory: workingDirectory.map { FilePath($0.path) },
            output: .string(limit: .max),
            error: .combinedWithOutput
        )
        let output = result.standardOutput
        guard result.terminationStatus.isSuccess else {
            throw XcodeProjectBuilder.Errors.commandFailed(command: commandLine, output: output)
        }
        if (printOutput || verbose) && !output.isEmpty {
            log(output.trimmingCharacters(in: .newlines))
        }
        return output
    }

    static func shellQuote(_ string: String) -> String {
        if !string.isEmpty && string.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=+,:@%".contains($0) }) {
            return string
        }
        return "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Runs `body` over `items` with at most `limit` concurrent tasks.
func forEachConcurrently<T: Sendable>(
    _ items: [T],
    limit: Int,
    _ body: @escaping @Sendable (T) async throws -> Void
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        var iterator = items.makeIterator()
        for _ in 0..<limit {
            guard let item = iterator.next() else { break }
            group.addTask { try await body(item) }
        }
        while try await group.next() != nil {
            if let item = iterator.next() {
                group.addTask { try await body(item) }
            }
        }
    }
}
