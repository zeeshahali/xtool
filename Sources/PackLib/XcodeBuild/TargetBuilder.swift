import Foundation
import XUtils
import XcodeProjects

/// Builds a single target of an Xcode project.
struct TargetBuilder: Sendable {
    typealias BuildFile = XcodeBuildModel.BuildFile
    typealias Location = XcodeBuildModel.Location

    let model: XcodeBuildModel
    let target: XcodeBuildModel.Target
    let settings: XcodeSettings
    let toolchain: XcodeToolchain
    let options: XcodeProjectBuilder.Options
    let runner: CommandRunner
    let log: XcodeProjectBuilder.Logger

    private var fileManager: FileManager { .default }

    private var productType: String { target.productType }
    private var isWrapper: Bool { !settings.string("WRAPPER_EXTENSION").isEmpty }

    var builtProductsDir: URL { url(settings.string("BUILT_PRODUCTS_DIR")) }
    var tempDir: URL { url(settings.string("TARGET_TEMP_DIR")) }
    private var derivedDir: URL { url(settings.string("DERIVED_FILE_DIR")) }
    var objectsDir: URL { url(settings.string("OBJECT_FILE_DIR")).appending(path: "arm64") }

    /// The product's location, e.g. `.../Release-iphoneos/Unity-iPhone.app`.
    private var productURL: URL { builtProductsDir.appending(path: settings.string("FULL_PRODUCT_NAME")) }
    /// The bundle's contents directory (same as the product for iOS bundles).
    private var contentsURL: URL { builtProductsDir.appending(path: settings.string("CONTENTS_FOLDER_PATH")) }
    private var executableURL: URL { builtProductsDir.appending(path: settings.string("EXECUTABLE_PATH")) }

    func url(_ path: String) -> URL {
        URL(fileURLWithPath: path, relativeTo: model.sourceRoot).standardizedFileURL
    }

    // swiftlint:disable:next cyclomatic_complexity
    func build() async throws -> XcodeProjectBuilder.Product {
        log("=== \(target.name) (\(settings.string("FULL_PRODUCT_NAME"))) ===")
        try fileManager.createDirectory(at: builtProductsDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: derivedDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: objectsDir, withIntermediateDirectories: true)

        if isWrapper {
            // start from a clean bundle so stale resources don't linger. Headers are
            // kept (and only replaced when changed) so that dependents don't recompile.
            let keep: Set<String> = ["Headers", "PrivateHeaders"]
            for child in (try? fileManager.contentsOfDirectory(atPath: productURL.path)) ?? []
            where !keep.contains(child) {
                try? fileManager.removeItem(at: productURL.appending(path: child))
            }
            try fileManager.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        }

        var objects: [URL] = []
        var linkInputs: [BuildFile] = []
        var resources: [BuildFile] = []
        var usesCxx = false
        var usesSwift = false

        for phase in target.buildPhases {
            switch phase {
            case .headers(let files):
                try copyHeaders(files)
            case .sources(let files):
                let result = try await compileSources(files)
                objects += result.objects
                usesCxx = usesCxx || result.usesCxx
                usesSwift = usesSwift || result.usesSwift
            case .frameworks(let files):
                linkInputs += files
            case .resources(let files):
                resources += files
            case .copyFiles(let phase):
                // copy phases may depend on the linked executable, so defer them until after linking
                _ = phase
            case .shellScript:
                break
            }
        }

        // Xcode runs phases in order, but in practice generated projects place
        // linking before resources/copy phases. Link first, then handle the rest in order.
        if !objects.isEmpty || productType == ProductType.application {
            try await link(objects: objects, inputs: linkInputs, usesCxx: usesCxx, usesSwift: usesSwift)
        }

        var compiledResources = ResourceResult()
        if isWrapper {
            compiledResources = try copyResources(resources)
        }

        for phase in target.buildPhases {
            switch phase {
            case .copyFiles(let phase):
                try copyFiles(phase)
            case .shellScript(let phase):
                try await runScript(phase)
            default:
                break
            }
        }

        if isWrapper {
            try writeInfoPlist(resources: compiledResources)
            if productType == ProductType.framework, settings.bool("DEFINES_MODULE") {
                try writeModuleMap()
            }
        }

        let entitlementsPath = settings.string("CODE_SIGN_ENTITLEMENTS")
        return .init(
            targetName: target.name,
            url: productURL,
            entitlements: entitlementsPath.isEmpty ? nil : url(entitlementsPath)
        )
    }

    // MARK: - Paths

    /// Resolves a file's location to an absolute URL.
    func resolve(_ location: Location) -> URL {
        let path = settings.expand(location.path)
        switch location.tree {
        case Location.absolute:
            return URL(fileURLWithPath: path)
        case Location.sourceRoot:
            return model.sourceRoot.appending(path: path).standardizedFileURL
        case Location.sdkRoot:
            return toolchain.sdk.appending(path: path)
        case Location.developerDir:
            return toolchain.developerDir.appending(path: path)
        default:
            let base = settings.string(location.tree)
            return url(base.isEmpty ? model.sourceRoot.path : base).appending(path: path).standardizedFileURL
        }
    }

    /// Expands search path settings, handling `$(inherited)`, quotes, and recursive (`/**`) entries.
    func searchPaths(_ key: String) -> [String] {
        settings.list(key).flatMap { entry -> [String] in
            guard !entry.isEmpty else { return [] }
            var path = entry
            var recursive = false
            if path.hasSuffix("/**") {
                path.removeLast(3)
                recursive = true
            } else if path.hasSuffix("**") {
                path.removeLast(2)
                recursive = true
            }
            let base = url(path)
            guard recursive else { return [base.path] }
            var results = [base.path]
            let enumerator = fileManager.enumerator(
                at: base,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            while let child = enumerator?.nextObject() as? URL {
                if child.pathExtension == "framework" || child.pathExtension == "xcframework" {
                    enumerator?.skipDescendants()
                    continue
                }
                if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    results.append(child.path)
                }
            }
            return results
        }
    }

    // MARK: - Headers

    private func copyHeaders(_ files: [BuildFile]) throws {
        guard isWrapper else { return }
        for file in files {
            let folderKey: String
            if file.attributes.contains("Public") {
                folderKey = "PUBLIC_HEADERS_FOLDER_PATH"
            } else if file.attributes.contains("Private") {
                folderKey = "PRIVATE_HEADERS_FOLDER_PATH"
            } else {
                continue
            }
            let source = resolve(file.file.location)
            let destinationDir = builtProductsDir.appending(path: settings.string(folderKey))
            try fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)
            let destination = destinationDir.appending(path: source.lastPathComponent)
            if let existing = try? Data(contentsOf: destination), existing == (try? Data(contentsOf: source)) {
                continue
            }
            try copyItem(source, to: destination)
        }
    }

    private func writeModuleMap() throws {
        let headers = builtProductsDir.appending(path: settings.string("PUBLIC_HEADERS_FOLDER_PATH"))
        let module = settings.string("PRODUCT_MODULE_NAME")
        let modules = contentsURL.appending(path: "Modules")
        let customMap = settings.string("MODULEMAP_FILE")
        try fileManager.createDirectory(at: modules, withIntermediateDirectories: true)
        let destination = modules.appending(path: "module.modulemap")
        if !customMap.isEmpty {
            try copyItem(url(customMap), to: destination)
            return
        }
        let umbrella = headers.appending(path: "\(module).h")
        guard fileManager.fileExists(atPath: umbrella.path) else { return }
        try Data("""
        framework module \(module) {
          umbrella header "\(module).h"
          export *
          module * { export * }
        }

        """.utf8).write(to: destination)
    }

    // MARK: - Compilation

    private struct CompileResult {
        var objects: [URL] = []
        var usesCxx = false
        var usesSwift = false
    }

    private enum Language: String {
        case c
        case objc = "objective-c"
        case cxx = "c++"
        case objcxx = "objective-c++"
        case asm = "assembler-with-cpp"
        case swift

        // swiftlint:disable:next cyclomatic_complexity
        init?(file: XcodeBuildModel.FileReference) {
            switch file.location.pathExtension {
            case "c": self = .c
            case "m": self = .objc
            case "mm": self = .objcxx
            case "cpp", "cc", "cxx", "c++", "cp": self = .cxx
            case "s": self = .asm
            case "swift": self = .swift
            default:
                switch file.fileType {
                case "sourcecode.c.c": self = .c
                case "sourcecode.c.objc": self = .objc
                case "sourcecode.cpp.cpp": self = .cxx
                case "sourcecode.cpp.objcpp": self = .objcxx
                case "sourcecode.asm", "sourcecode.asm.asm": self = .asm
                case "sourcecode.swift": self = .swift
                default: return nil
                }
            }
        }

        var isCxx: Bool { self == .cxx || self == .objcxx }
        var isObjC: Bool { self == .objc || self == .objcxx }
    }

    struct CompileJob: Sendable {
        var source: URL
        var object: URL
        var arguments: [String]
    }

    private func compileSources(_ files: [BuildFile]) async throws -> CompileResult {
        var result = CompileResult()
        var swiftFiles: [URL] = []
        var jobs: [CompileJob] = []
        var seenObjects: Set<String> = []

        for file in files {
            guard let language = Language(file: file.file) else {
                let ext = file.file.location.pathExtension
                if !["h", "hpp", "hh", "inl", "pch", "modulemap", "txt", "md", "plist"].contains(ext) {
                    log("warning: skipping unsupported source file \(file.file.location.lastPathComponent)")
                }
                continue
            }
            let source = resolve(file.file.location)
            if language == .swift {
                swiftFiles.append(source)
                continue
            }
            result.usesCxx = result.usesCxx || language.isCxx
            var objectName = "\(source.deletingPathExtension().lastPathComponent)-\(Self.stableHash(source.path)).o"
            while !seenObjects.insert(objectName).inserted { objectName = "_" + objectName }
            let object = objectsDir.appending(path: objectName)
            let perFileFlags = file.compilerFlags.map { XcodeSettings.splitWords(settings.expand($0)) } ?? []
            let arguments = clangArguments(language: language)
                + perFileFlags
                + ["-MMD", "-MF", object.deletingPathExtension().path + ".d", "-c", source.path, "-o", object.path]
            jobs.append(CompileJob(source: source, object: object, arguments: arguments))
        }

        // compile Swift first so that the generated -Swift.h header is available to ObjC
        if !swiftFiles.isEmpty {
            result.usesSwift = true
            result.objects.append(try await compileSwift(swiftFiles))
        }

        try prepareHeaderMap()

        try await runCompileJobs(jobs)
        result.objects += jobs.map(\.object)
        return result
    }

    /// Compiles jobs in parallel, skipping those that are up to date.
    func runCompileJobs(_ jobs: [CompileJob]) async throws {
        let pending = jobs.filter { !isUpToDate($0) }
        if !jobs.isEmpty {
            log("Compiling \(pending.count) of \(jobs.count) source files (\(options.jobs) jobs)")
        }
        let counter = ProgressCounter(total: pending.count)
        let clang = toolchain.clang
        let runner = self.runner
        let log = self.log
        try await forEachConcurrently(pending, limit: options.jobs) { job in
            try await runner.run(clang, job.arguments)
            try Data(job.arguments.joined(separator: "\u{0}").utf8)
                .write(to: job.object.deletingPathExtension().appendingPathExtension("args"))
            let done = await counter.increment()
            if done % 100 == 0 || done == counter.total {
                log("  [\(done)/\(counter.total)] compiled")
            }
        }
    }

    private actor ProgressCounter {
        nonisolated let total: Int
        private var count = 0
        init(total: Int) { self.total = total }
        func increment() -> Int {
            count += 1
            return count
        }
    }

    /// Whether the object file is newer than its source and all headers it depends on,
    /// and was built with the same arguments.
    private func isUpToDate(_ job: CompileJob) -> Bool {
        let argsFile = job.object.deletingPathExtension().appendingPathExtension("args")
        let depFile = job.object.deletingPathExtension().appendingPathExtension("d")
        guard let objectDate = modificationDate(job.object),
              let previousArgs = try? Data(contentsOf: argsFile),
              previousArgs == Data(job.arguments.joined(separator: "\u{0}").utf8),
              let deps = try? String(contentsOf: depFile, encoding: .utf8)
        else { return false }
        guard let colon = deps.range(of: ": ") ?? deps.range(of: ":\n") else { return false }
        let list = deps[colon.upperBound...].replacingOccurrences(of: "\\\n", with: " ")
        for dependency in XcodeSettings.splitWords(list) {
            guard let date = modificationDate(URL(fileURLWithPath: dependency)), date <= objectDate else {
                return false
            }
        }
        return true
    }

    private func modificationDate(_ url: URL) -> Date? {
        // follow symlinks (e.g. in the header map) to the real file
        (try? fileManager.attributesOfItem(atPath: url.resolvingSymlinksInPath().path))?[.modificationDate] as? Date
    }

    static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 36)
    }

    private var headerMapDir: URL { tempDir.appending(path: "HeaderMap") }

    /// Emulates Xcode's header maps, which let `#include "Foo.h"` find any header in the project.
    private func prepareHeaderMap() throws {
        guard settings.bool("USE_HEADERMAP", default: true) else { return }
        try? fileManager.removeItem(at: headerMapDir)
        try fileManager.createDirectory(at: headerMapDir, withIntermediateDirectories: true)
        let headerExtensions: Set<String> = ["h", "hh", "hpp", "hxx", "inl", "ipp", "tcc"]
        var seen: Set<String> = []
        for file in model.files where headerExtensions.contains(file.location.pathExtension) {
            let name = file.location.lastPathComponent
            guard seen.insert(name).inserted else { continue }
            let source = resolve(file.location)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try fileManager.createSymbolicLink(at: headerMapDir.appending(path: name), withDestinationURL: source)
        }
    }

    var deploymentTarget: String {
        let value = settings.string("IPHONEOS_DEPLOYMENT_TARGET")
        return value.isEmpty ? "15.0" : value
    }

    var targetTriple: String { "arm64-apple-ios\(deploymentTarget)" }

    // swiftlint:disable:next cyclomatic_complexity
    private func clangArguments(language: Language) -> [String] {
        var args = [
            "-x", language.rawValue,
            "-target", targetTriple,
            "-isysroot", toolchain.sdk.path,
            "-fmessage-length=0",
            "-fdiagnostics-show-note-include-stack",
            "-fmacro-backtrace-limit=0",
            // Apple clang flags in projects may not be known to the host's clang
            "-Wno-unknown-warning-option",
            "-Wno-unused-command-line-argument",
            "-Qunused-arguments",
        ]

        let optimization = settings.string("GCC_OPTIMIZATION_LEVEL")
        args.append("-O\(optimization.isEmpty ? "s" : optimization)")
        if settings.bool("GCC_GENERATE_DEBUGGING_SYMBOLS", default: true),
           !settings.string("DEBUG_INFORMATION_FORMAT").isEmpty {
            args.append("-g")
        }

        if language.isCxx {
            let std = settings.string("CLANG_CXX_LANGUAGE_STANDARD")
            if !std.isEmpty && std != "compiler-default" { args.append("-std=\(std)") }
            let stdlib = settings.string("CLANG_CXX_LIBRARY")
            args.append("-stdlib=\(stdlib.isEmpty || stdlib == "compiler-default" ? "libc++" : stdlib)")
            if !settings.bool("GCC_ENABLE_CPP_EXCEPTIONS", default: true) { args.append("-fno-exceptions") }
            if !settings.bool("GCC_ENABLE_CPP_RTTI", default: true) { args.append("-fno-rtti") }
            if settings.bool("GCC_INLINES_ARE_PRIVATE_EXTERN") { args.append("-fvisibility-inlines-hidden") }
        } else if language != .asm {
            let std = settings.string("GCC_C_LANGUAGE_STANDARD")
            if !std.isEmpty && std != "compiler-default" { args.append("-std=\(std)") }
        }

        if language.isObjC {
            if settings.bool("CLANG_ENABLE_OBJC_ARC") { args.append("-fobjc-arc") }
            if settings.bool("CLANG_ENABLE_OBJC_WEAK") { args.append("-fobjc-weak") }
            if !settings.bool("GCC_ENABLE_OBJC_EXCEPTIONS", default: true) { args.append("-fno-objc-exceptions") }
        }

        if settings.bool("CLANG_ENABLE_MODULES") && language != .asm {
            args += ["-fmodules", "-fmodules-cache-path=\(settings.string("MODULE_CACHE_DIR"))"]
            if language.isCxx { args.append("-fcxx-modules") }
        }

        if settings.bool("GCC_SYMBOLS_PRIVATE_EXTERN") { args.append("-fvisibility=hidden") }
        if settings.bool("GCC_NO_COMMON_BLOCKS") { args.append("-fno-common") }
        if settings.isDefined("GCC_STRICT_ALIASING") {
            args.append(settings.bool("GCC_STRICT_ALIASING") ? "-fstrict-aliasing" : "-fno-strict-aliasing")
        }
        if settings.bool("GCC_UNROLL_LOOPS") { args.append("-funroll-loops") }
        if settings.bool("GCC_FAST_MATH") { args.append("-ffast-math") }
        if settings.bool("APPLICATION_EXTENSION_API_ONLY") { args.append("-fapplication-extension") }
        if settings.bool("GCC_WARN_INHIBIT_ALL_WARNINGS") { args.append("-w") }
        if settings.bool("ENABLE_NS_ASSERTIONS", default: true) == false { args.append("-DNS_BLOCK_ASSERTIONS=1") }

        for definition in settings.list("GCC_PREPROCESSOR_DEFINITIONS")
            + settings.list("GCC_PREPROCESSOR_DEFINITIONS_NOT_USED_IN_PRECOMPS") {
            args.append("-D\(definition)")
        }

        // search paths, in roughly the order Xcode uses
        if settings.bool("USE_HEADERMAP", default: true) {
            args += ["-iquote", headerMapDir.path]
        }
        args += ["-I", builtProductsDir.appending(path: "include").path]
        let userPaths = searchPaths("USER_HEADER_SEARCH_PATHS")
        let alwaysSearchUserPaths = settings.bool("ALWAYS_SEARCH_USER_PATHS")
        for path in userPaths {
            args += [alwaysSearchUserPaths ? "-I" : "-iquote", path]
        }
        for path in searchPaths("HEADER_SEARCH_PATHS") {
            args += ["-I", path]
        }
        args += ["-I", derivedDir.path, "-I", derivedDir.appending(path: "arm64").path]
        args += ["-F", builtProductsDir.path]
        for path in searchPaths("FRAMEWORK_SEARCH_PATHS") {
            args += ["-F", path]
        }
        for path in searchPaths("SYSTEM_HEADER_SEARCH_PATHS") {
            args += ["-isystem", path]
        }
        for path in searchPaths("SYSTEM_FRAMEWORK_SEARCH_PATHS") {
            args += ["-iframework", path]
        }

        let prefixHeader = settings.string("GCC_PREFIX_HEADER")
        if !prefixHeader.isEmpty && language != .asm {
            args += ["-include", url(prefixHeader).path]
        }

        args += settings.list("WARNING_CFLAGS")
        args += language.isCxx ? settings.list("OTHER_CPLUSPLUSFLAGS") : settings.list("OTHER_CFLAGS")
        return args.filter { !Self.unsupportedCompilerFlags.contains($0) }
    }

    /// Flags that only Apple's toolchain understands and that are safe to drop.
    static let unsupportedCompilerFlags: Set<String> = [
        "-fembed-bitcode", "-fembed-bitcode-marker", "-gmodules",
    ]

    private func compileSwift(_ files: [URL]) async throws -> URL {
        let module = settings.string("PRODUCT_MODULE_NAME")
        let object = objectsDir.appending(path: "\(module)-swift.o")
        var args = [
            "-target", targetTriple,
            "-sdk", toolchain.sdk.path,
            "-module-name", module,
            "-c", "-wmo",
            "-module-cache-path", settings.string("MODULE_CACHE_DIR"),
            "-Xfrontend", "-enable-cross-import-overlays",
            "-emit-objc-header", "-emit-objc-header-path", derivedDir.appending(path: "\(module)-Swift.h").path,
            "-o", object.path,
        ]
        if let resourceDir = toolchain.swiftResourceDir {
            args += ["-resource-dir", resourceDir.path]
        }
        let optimization = settings.string("SWIFT_OPTIMIZATION_LEVEL")
        args.append(optimization.isEmpty ? "-O" : optimization)
        if !files.contains(where: { $0.lastPathComponent == "main.swift" }) {
            args.append("-parse-as-library")
        }
        if let major = settings.string("SWIFT_VERSION").split(separator: ".").first {
            args += ["-swift-version", String(major)]
        }
        for condition in settings.list("SWIFT_ACTIVE_COMPILATION_CONDITIONS") {
            args += ["-D", condition]
        }
        let bridgingHeader = settings.string("SWIFT_OBJC_BRIDGING_HEADER")
        if !bridgingHeader.isEmpty {
            args += ["-import-objc-header", url(bridgingHeader).path]
        }
        args += ["-I", builtProductsDir.path, "-F", builtProductsDir.path]
        for path in searchPaths("SWIFT_INCLUDE_PATHS") { args += ["-I", path] }
        for path in searchPaths("FRAMEWORK_SEARCH_PATHS") { args += ["-F", path] }
        for path in searchPaths("HEADER_SEARCH_PATHS") { args += ["-Xcc", "-I", "-Xcc", path] }
        for definition in settings.list("GCC_PREPROCESSOR_DEFINITIONS") { args += ["-Xcc", "-D\(definition)"] }
        if settings.bool("APPLICATION_EXTENSION_API_ONLY") { args.append("-application-extension") }
        args += settings.list("OTHER_SWIFT_FLAGS")
        args += files.map(\.path)

        log("Compiling \(files.count) Swift files")
        try await runner.run(toolchain.swiftc, args)
        return object
    }

}

// MARK: - Linking

extension TargetBuilder {

    // swiftlint:disable:next cyclomatic_complexity
    private func link(objects: [URL], inputs: [BuildFile], usesCxx: Bool, usesSwift: Bool) async throws {
        let output = executableURL
        try fileManager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fileList = tempDir.appending(path: "\(target.name).LinkFileList")
        try Data(objects.map(\.path).joined(separator: "\n").utf8).write(to: fileList)

        if productType == ProductType.staticLibrary || productType == ProductType.staticFramework {
            log("Archiving \(output.lastPathComponent)")
            try? fileManager.removeItem(at: output)
            try await runner.run(toolchain.libtool, toolchain.archiveArguments(output: output, fileList: fileList))
            return
        }

        var args = [
            "-target", targetTriple,
            "-isysroot", toolchain.sdk.path,
            "-Qunused-arguments",
        ]
        if let linker = toolchain.linker {
            // -fuse-ld=lld makes clang pass lld-style arguments (e.g. -platform_version)
            args += ["-fuse-ld=lld", "--ld-path=\(linker.path)"]
        }
        switch productType {
        case ProductType.framework, ProductType.dynamicLibrary:
            args += ["-dynamiclib", "-install_name", settings.string("LD_DYLIB_INSTALL_NAME")]
        case ProductType.bundle:
            args.append("-bundle")
        default:
            if productType.hasPrefix("com.apple.product-type.app-extension") {
                args += ["-e", "_NSExtensionMain", "-fapplication-extension"]
            }
        }
        args += ["-filelist", fileList.path]
        args += ["-L", builtProductsDir.path, "-F", builtProductsDir.path]
        for path in searchPaths("LIBRARY_SEARCH_PATHS") { args += ["-L", path] }
        for path in searchPaths("FRAMEWORK_SEARCH_PATHS") { args += ["-F", path] }
        for path in settings.list("LD_RUNPATH_SEARCH_PATHS") { args += ["-Xlinker", "-rpath", "-Xlinker", path] }
        if settings.bool("DEAD_CODE_STRIPPING", default: true) { args.append("-dead_strip") }
        args += XcodeProjectBuilder.stripLinkerFlags(settings)
        if settings.bool("CLANG_ENABLE_OBJC_ARC") { args.append("-fobjc-link-runtime") }
        if settings.bool("APPLICATION_EXTENSION_API_ONLY") { args.append("-fapplication-extension") }

        for input in inputs {
            args += try linkArguments(for: input)
        }

        if usesSwift {
            for dir in toolchain.swiftLibraryDirs { args += ["-L", dir.path] }
        }
        if usesCxx || inputs.contains(where: { $0.file.location.pathExtension == "a" }) {
            // static libraries (e.g. Unity's libiPhone-lib.a) usually contain C++ code
            args += ["-lc++"]
        }
        args += settings.list("OTHER_LDFLAGS")
        if let compilerRT = toolchain.compilerRTLibrary {
            args.append(compilerRT.path)
        }
        args += ["-o", output.path]

        log("Linking \(output.lastPathComponent)")
        try await runner.run(toolchain.clang, XcodeProjectBuilder.filterLinkerFlags(args))
    }

    private func linkArguments(for input: BuildFile) throws -> [String] {
        let location = input.file.location
        let weak = input.attributes.contains("Weak")
        let name = (location.lastPathComponent as NSString).deletingPathExtension
        let resolved = resolve(location)
        switch location.pathExtension {
        case "framework":
            let inSDK = location.tree == Location.sdkRoot || resolved.path.hasPrefix(toolchain.sdk.path)
            var args: [String] = []
            if !inSDK { args += ["-F", resolved.deletingLastPathComponent().path] }
            args += [weak ? "-weak_framework" : "-framework", name]
            return args
        case "xcframework":
            guard let slice = XCFramework.slice(at: resolved) else {
                log("warning: no iOS device slice in \(location.lastPathComponent)")
                return []
            }
            if slice.pathExtension == "framework" {
                let frameworkName = slice.deletingPathExtension().lastPathComponent
                return ["-F", slice.deletingLastPathComponent().path, weak ? "-weak_framework" : "-framework", frameworkName]
            }
            return [slice.path]
        case "a", "o":
            return [resolved.path]
        case "tbd", "dylib":
            var lib = name
            if lib.hasPrefix("lib") { lib.removeFirst(3) }
            var args: [String] = []
            if location.tree != Location.sdkRoot && !resolved.path.hasPrefix(toolchain.sdk.path) {
                args += ["-L", resolved.deletingLastPathComponent().path]
            }
            args.append(weak ? "-weak-l\(lib)" : "-l\(lib)")
            return args
        default:
            log("warning: don't know how to link \(location.lastPathComponent); skipping")
            return []
        }
    }

    // MARK: - Resources

    struct ResourceResult {
        var infoPlist: [String: Any] = [:]
        var skippedStoryboards: Set<String> = []
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func copyResources(_ files: [BuildFile]) throws -> ResourceResult {
        var result = ResourceResult()
        var catalogs: [URL] = []
        var skipped: [String] = []
        let destination = builtProductsDir.appending(path: settings.string("UNLOCALIZED_RESOURCES_FOLDER_PATH"))
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        if !files.isEmpty {
            log("Copying \(files.count) resources")
        }

        for file in files {
            let location = file.file.location
            let ext = location.pathExtension
            switch ext {
            case "xcassets":
                catalogs.append(resolve(location))
                continue
            case "storyboard", "xib":
                let name = (location.lastPathComponent as NSString).deletingPathExtension
                result.skippedStoryboards.insert(name)
                skipped.append(location.lastPathComponent)
                continue
            case "xcdatamodeld", "xcdatamodel", "xcmappingmodel", "metal", "intentdefinition", "xcstrings",
                "rcproject", "mlmodel", "mlpackage", "icon":
                skipped.append(location.lastPathComponent)
                continue
            default:
                break
            }

            if !file.file.variants.isEmpty {
                // localized resource: keep the `xx.lproj/` directory
                for variant in file.file.variants {
                    let source = resolve(variant)
                    let lproj = source.deletingLastPathComponent().lastPathComponent
                    let directory = lproj.hasSuffix(".lproj") ? destination.appending(path: lproj) : destination
                    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                    if ["storyboard", "xib"].contains(source.pathExtension) { continue }
                    try copyItem(source, to: directory.appending(path: source.lastPathComponent))
                }
                continue
            }

            let source = resolve(location)
            guard fileManager.fileExists(atPath: source.path) else {
                if location.tree == Location.builtProductsDir {
                    log("warning: missing build product \(location.lastPathComponent)")
                    continue
                }
                throw XcodeProjectBuilder.Errors.missingFile(source.path)
            }
            try copyItem(source, to: destination.appending(path: source.lastPathComponent))
        }

        if !catalogs.isEmpty {
            let appIcon = settings.string("ASSETCATALOG_COMPILER_APPICON_NAME")
            let compiler = AssetCatalogCompiler(appIconName: appIcon.isEmpty ? "AppIcon" : appIcon)
            let output = try compiler.compile(catalogs: catalogs, into: destination)
            result.infoPlist.merge(output.infoPlist) { $1 }
            if !output.skipped.isEmpty {
                log("warning: asset catalog entries other than the app icon are not supported on this platform; " +
                    "skipped: \(output.skipped.joined(separator: ", "))")
            }
        }
        if !skipped.isEmpty {
            log("warning: these resources require Xcode-only compilers and were skipped: " +
                skipped.joined(separator: ", "))
        }
        return result
    }

    private func copyItem(_ source: URL, to destination: URL) throws {
        guard fileManager.fileExists(atPath: source.path) else {
            throw XcodeProjectBuilder.Errors.missingFile(source.path)
        }
        try? fileManager.removeItem(at: destination)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: source, to: destination)
    }

    // MARK: - Copy Files

    // swiftlint:disable:next cyclomatic_complexity
    private func copyFiles(_ phase: XcodeBuildModel.CopyFilesPhase) throws {
        if phase.deploymentPostprocessingOnly && !settings.bool("DEPLOYMENT_POSTPROCESSING") { return }
        let base: URL
        switch phase.destination {
        case .absolutePath: base = URL(fileURLWithPath: "/")
        case .productsDirectory: base = builtProductsDir
        case .wrapper: base = contentsURL
        case .executables: base = builtProductsDir.appending(path: settings.string("EXECUTABLE_FOLDER_PATH"))
        case .resources: base = builtProductsDir.appending(path: settings.string("UNLOCALIZED_RESOURCES_FOLDER_PATH"))
        case .frameworks: base = builtProductsDir.appending(path: settings.string("FRAMEWORKS_FOLDER_PATH"))
        case .sharedFrameworks: base = contentsURL.appending(path: "SharedFrameworks")
        case .sharedSupport: base = contentsURL.appending(path: "SharedSupport")
        case .plugins: base = builtProductsDir.appending(path: settings.string("PLUGINS_FOLDER_PATH"))
        case .other: base = contentsURL
        }
        let subpath = settings.expand(phase.subpath)
        let directory = subpath.isEmpty ? base : base.appending(path: subpath)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        for file in phase.files {
            var source = resolve(file.file.location)
            if source.pathExtension == "xcframework" {
                guard let slice = XCFramework.slice(at: source) else {
                    log("warning: no iOS device slice in \(source.lastPathComponent)")
                    continue
                }
                source = slice
            }
            guard fileManager.fileExists(atPath: source.path) else {
                log("warning: \(phase.name ?? "Copy Files"): missing \(source.path)")
                continue
            }
            let destination = directory.appending(path: source.lastPathComponent)
            try copyItem(source, to: destination)
            let removeHeaders = file.attributes.contains("RemoveHeadersOnCopy")
                || settings.bool("REMOVE_HEADERS_FROM_EMBEDDED_BUNDLES", default: true)
            if removeHeaders && ["framework", "appex", "bundle"].contains(destination.pathExtension) {
                for folder in ["Headers", "PrivateHeaders", "Modules"] {
                    try? fileManager.removeItem(at: destination.appending(path: folder))
                }
            }
        }
    }

    // MARK: - Scripts

    private func runScript(_ phase: XcodeBuildModel.ShellScriptPhase) async throws {
        let name = phase.name ?? "Run Script"
        if phase.deploymentPostprocessingOnly && !settings.bool("DEPLOYMENT_POSTPROCESSING") { return }
        if let il2cpp = UnityIl2CppScript(script: settings.expand(phase.script)) {
            // Unity's il2cpp tool is macOS/Windows-only; compile its generated C++ natively instead
            try await compileIl2Cpp(il2cpp)
            return
        }
        guard options.runScripts else {
            log("warning: skipping build phase '\(name)' (pass --run-scripts to run script phases)")
            return
        }
        log("Running script '\(name)'")
        let scriptFile = tempDir.appending(path: "Script-\(Self.stableHash(name + phase.script)).sh")
        try Data(phase.script.utf8).write(to: scriptFile)

        var environment: [String: String] = [:]
        for key in settings.allKeys where !key.contains("[") {
            environment[key] = settings.string(key)
        }
        for (index, path) in phase.inputPaths.enumerated() {
            environment["SCRIPT_INPUT_FILE_\(index)"] = settings.expand(path)
        }
        environment["SCRIPT_INPUT_FILE_COUNT"] = "\(phase.inputPaths.count)"
        for (index, path) in phase.outputPaths.enumerated() {
            environment["SCRIPT_OUTPUT_FILE_\(index)"] = settings.expand(path)
        }
        environment["SCRIPT_OUTPUT_FILE_COUNT"] = "\(phase.outputPaths.count)"

        let shellWords = XcodeSettings.splitWords(phase.shellPath)
        let shell = URL(fileURLWithPath: shellWords.first ?? "/bin/sh")
        try await runner.run(
            shell,
            Array(shellWords.dropFirst()) + [scriptFile.path],
            environment: environment,
            workingDirectory: model.sourceRoot,
            printOutput: true
        )
    }

    // MARK: - Info.plist

    // swiftlint:disable:next cyclomatic_complexity
    private func writeInfoPlist(resources: ResourceResult) throws {
        var plist: [String: Any] = [:]
        let infoPlistPath = settings.string("INFOPLIST_FILE")
        if !infoPlistPath.isEmpty {
            let data = try Data(contentsOf: url(infoPlistPath))
            plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] ?? [:]
            if settings.bool("INFOPLIST_EXPAND_BUILD_SETTINGS", default: true) {
                plist = expandPlist(plist) as? [String: Any] ?? plist
            }
        }

        if settings.bool("GENERATE_INFOPLIST_FILE") || infoPlistPath.isEmpty {
            for key in settings.allKeys where key.hasPrefix("INFOPLIST_KEY_") {
                let plistKey = String(key.dropFirst("INFOPLIST_KEY_".count))
                guard plist[plistKey] == nil else { continue }
                let value = settings.string(key)
                switch value {
                case "YES": plist[plistKey] = true
                case "NO": plist[plistKey] = false
                default: plist[plistKey] = value
                }
            }
            let version = settings.string("MARKETING_VERSION")
            if !version.isEmpty, plist["CFBundleShortVersionString"] == nil {
                plist["CFBundleShortVersionString"] = version
            }
            let build = settings.string("CURRENT_PROJECT_VERSION")
            if !build.isEmpty, plist["CFBundleVersion"] == nil {
                plist["CFBundleVersion"] = build
            }
        }

        func setDefault(_ key: String, _ value: @autoclosure () -> Any?) {
            if plist[key] == nil, let value = value() {
                if let string = value as? String, string.isEmpty { return }
                plist[key] = value
            }
        }

        let packageType: String = switch productType {
        case ProductType.framework, ProductType.staticFramework: "FMWK"
        case ProductType.bundle: "BNDL"
        default: productType.hasPrefix("com.apple.product-type.app-extension") ? "XPC!" : "APPL"
        }
        setDefault("CFBundleExecutable", settings.string("EXECUTABLE_NAME"))
        setDefault("CFBundleIdentifier", settings.string("PRODUCT_BUNDLE_IDENTIFIER"))
        setDefault("CFBundleName", settings.string("PRODUCT_NAME"))
        setDefault("CFBundlePackageType", packageType)
        setDefault("CFBundleInfoDictionaryVersion", "6.0")
        setDefault("CFBundleDevelopmentRegion", "en")
        setDefault("CFBundleShortVersionString", "1.0")
        setDefault("CFBundleVersion", "1")
        plist["CFBundleSupportedPlatforms"] = ["iPhoneOS"]
        plist["MinimumOSVersion"] = deploymentTarget
        plist["DTPlatformName"] = "iphoneos"
        plist["DTPlatformVersion"] = toolchain.sdkVersion
        plist["DTSDKName"] = settings.string("SDK_NAME")

        if productType == ProductType.application || productType.hasPrefix("com.apple.product-type.app-extension") {
            let families = settings.string("TARGETED_DEVICE_FAMILY")
                .split(whereSeparator: { $0 == "," || $0 == " " })
                .compactMap { Int($0) }
            plist["UIDeviceFamily"] = families.isEmpty ? [1] : families
        }
        if productType == ProductType.application {
            setDefault("LSRequiresIPhoneOS", true)
        }

        plist.merge(resources.infoPlist) { $1 }

        // storyboards can't be compiled outside of macOS. Fall back to an empty
        // launch screen configuration so the app still launches full-screen.
        var removedLaunchStoryboard = false
        for key in plist.keys where key.hasPrefix("UILaunchStoryboardName") {
            if let name = plist[key] as? String, resources.skippedStoryboards.contains(name) {
                plist.removeValue(forKey: key)
                removedLaunchStoryboard = true
            }
        }
        if removedLaunchStoryboard && plist["UILaunchScreen"] == nil {
            plist["UILaunchScreen"] = [String: Any]()
            log("note: replaced launch storyboard with an empty UILaunchScreen configuration")
        }
        for key in plist.keys where key.hasPrefix("UIMainStoryboardFile") {
            if let name = plist[key] as? String, resources.skippedStoryboards.contains(name) {
                log("warning: main storyboard '\(name)' could not be compiled and was removed from Info.plist")
                plist.removeValue(forKey: key)
            }
        }

        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let destination = builtProductsDir.appending(path: settings.string("INFOPLIST_PATH"))
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination)
    }

    private func expandPlist(_ value: Any) -> Any {
        switch value {
        case let string as String:
            settings.expand(string)
        case let array as [Any]:
            array.map(expandPlist)
        case let dictionary as [String: Any]:
            dictionary.mapValues(expandPlist)
        default:
            value
        }
    }
}

enum XCFramework {
    /// Returns the path to the iOS device slice's library or framework.
    static func slice(at xcframework: URL) -> URL? {
        let infoURL = xcframework.appending(path: "Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let libraries = plist["AvailableLibraries"] as? [[String: Any]]
        else { return nil }
        for library in libraries {
            guard library["SupportedPlatform"] as? String == "ios",
                  library["SupportedPlatformVariant"] == nil,
                  (library["SupportedArchitectures"] as? [String])?.contains("arm64") ?? true,
                  let identifier = library["LibraryIdentifier"] as? String,
                  let path = library["LibraryPath"] as? String
            else { continue }
            return xcframework.appending(path: identifier).appending(path: path)
        }
        return nil
    }
}
