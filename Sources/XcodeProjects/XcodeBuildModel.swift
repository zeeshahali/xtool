import Foundation
private import XcodeProj

/// A flattened, build-oriented view of an Xcode project (`.pbxproj`).
///
/// This contains the information required to build the targets in a project
/// without Xcode: build settings, build phases, file locations, and dependencies.
public struct XcodeBuildModel: Sendable {
    /// A value of a build setting as stored in the project.
    public enum Setting: Sendable, Hashable {
        case string(String)
        case array([String])
    }

    /// A path that is relative to a source tree, e.g. `SOURCE_ROOT` or `SDKROOT`.
    public struct Location: Sendable, Hashable, CustomStringConvertible {
        public static let sourceRoot = "SOURCE_ROOT"
        public static let absolute = "<absolute>"
        public static let builtProductsDir = "BUILT_PRODUCTS_DIR"
        public static let sdkRoot = "SDKROOT"
        public static let developerDir = "DEVELOPER_DIR"

        /// The name of the source tree, e.g. `SOURCE_ROOT` or `<absolute>`.
        public var tree: String
        /// The path relative to the source tree.
        public var path: String

        public init(tree: String, path: String) {
            self.tree = tree
            self.path = path
        }

        public var description: String {
            tree == Self.absolute ? path : "$(\(tree))/\(path)"
        }

        public var lastPathComponent: String {
            (path as NSString).lastPathComponent
        }

        public var pathExtension: String {
            (path as NSString).pathExtension.lowercased()
        }
    }

    /// A file referenced from a build phase.
    public struct FileReference: Sendable, Hashable {
        public var location: Location
        /// The explicit or last-known file type, e.g. `sourcecode.c.objc` or `folder`.
        public var fileType: String?
        /// For localized resources (variant groups), the per-language variants.
        public var variants: [Location]

        public init(location: Location, fileType: String?, variants: [Location] = []) {
            self.location = location
            self.fileType = fileType
            self.variants = variants
        }

        /// Whether this is a "folder reference" (as opposed to a group), which is copied verbatim.
        public var isFolderReference: Bool {
            fileType == "folder"
        }
    }

    public struct BuildFile: Sendable, Hashable {
        public var file: FileReference
        /// Per-file compiler flags (`COMPILER_FLAGS`).
        public var compilerFlags: String?
        /// Build file attributes, e.g. `Weak` or `CodeSignOnCopy`.
        public var attributes: [String]

        public init(file: FileReference, compilerFlags: String? = nil, attributes: [String] = []) {
            self.file = file
            self.compilerFlags = compilerFlags
            self.attributes = attributes
        }
    }

    public struct CopyFilesPhase: Sendable, Hashable {
        public enum Destination: Sendable, Hashable {
            case absolutePath
            case productsDirectory
            case wrapper
            case executables
            case resources
            case frameworks
            case sharedFrameworks
            case sharedSupport
            case plugins
            case other(UInt)
        }

        public var name: String?
        public var destination: Destination
        public var subpath: String
        public var files: [BuildFile]
        public var deploymentPostprocessingOnly: Bool
    }

    public struct ShellScriptPhase: Sendable, Hashable {
        public var name: String?
        public var shellPath: String
        public var script: String
        public var inputPaths: [String]
        public var outputPaths: [String]
        public var deploymentPostprocessingOnly: Bool
    }

    public enum BuildPhase: Sendable, Hashable {
        case sources([BuildFile])
        case frameworks([BuildFile])
        case resources([BuildFile])
        case headers([BuildFile])
        case copyFiles(CopyFilesPhase)
        case shellScript(ShellScriptPhase)
    }

    public struct Configuration: Sendable, Hashable {
        public var name: String
        public var settings: [String: Setting]
        /// The `.xcconfig` file this configuration is based on, if any.
        public var baseConfiguration: Location?
    }

    public struct Target: Sendable, Hashable {
        public var name: String
        public var productName: String?
        /// The product type identifier, e.g. `com.apple.product-type.application`.
        public var productType: String
        public var configurations: [Configuration]
        public var defaultConfigurationName: String?
        public var buildPhases: [BuildPhase]
        /// Names of targets in this project that this target depends on.
        public var dependencies: [String]
        /// Whether this is an aggregate target (which only runs build phases).
        public var isAggregate: Bool

        public func configuration(named name: String) -> Configuration? {
            configurations.first { $0.name == name }
        }
    }

    public var name: String
    /// The `.xcodeproj` bundle URL.
    public var url: URL
    /// The project's source root (`SRCROOT`).
    public var sourceRoot: URL
    public var configurations: [Configuration]
    public var defaultConfigurationName: String?
    public var targets: [Target]
    /// Every file referenced from the project navigator (excluding groups).
    public var files: [FileReference]

    public func configuration(named name: String) -> Configuration? {
        configurations.first { $0.name == name }
    }

    public func target(named name: String) -> Target? {
        targets.first { $0.name == name }
    }

    public enum Errors: Error, CustomStringConvertible {
        case noRootObject(String)

        public var description: String {
            switch self {
            case .noRootObject(let path):
                "The project at '\(path)' does not have a root object"
            }
        }
    }
}

extension XcodeBuildModel {
    /// Reads the build model from the `.xcodeproj` at the given URL.
    public init(contentsOf url: URL) throws {
        let project = try XcodeProject(url: url)
        let pbxprojURL = project.url.appending(path: "project.pbxproj")
        let pbxproj = try PBXProj(data: Data(contentsOf: pbxprojURL))
        guard let root = try pbxproj.rootProject() else {
            throw Errors.noRootObject(pbxprojURL.path)
        }

        var converter = Converter()
        converter.indexParents(root.mainGroup)

        self.name = project.url.deletingPathExtension().lastPathComponent
        self.url = project.url
        self.sourceRoot = project.sourceRoot
        self.configurations = root.buildConfigurationList.buildConfigurations.map(converter.configuration)
        self.defaultConfigurationName = root.buildConfigurationList.defaultConfigurationName
        self.targets = root.targets.map(converter.target)
        self.files = converter.allFiles(root.mainGroup)
    }
}

private struct Converter {
    private var parents: [ObjectIdentifier: PBXFileElement] = [:]

    mutating func indexParents(_ group: PBXGroup?) {
        guard let group else { return }
        for child in group.children {
            parents[ObjectIdentifier(child)] = group
            if let childGroup = child as? PBXGroup {
                indexParents(childGroup)
            }
        }
    }

    func allFiles(_ group: PBXGroup?) -> [XcodeBuildModel.FileReference] {
        guard let group else { return [] }
        return group.children.flatMap { child -> [XcodeBuildModel.FileReference] in
            if child is PBXVariantGroup {
                [fileReference(child)]
            } else if let childGroup = child as? PBXGroup {
                allFiles(childGroup)
            } else {
                [fileReference(child)]
            }
        }
    }

    private func parent(of element: PBXFileElement) -> PBXFileElement? {
        parents[ObjectIdentifier(element)] ?? element.parent
    }

    func location(of element: PBXFileElement) -> XcodeBuildModel.Location {
        var components: [String] = []
        var current: PBXFileElement? = element
        while let element = current {
            if let path = element.path, !path.isEmpty {
                if path.hasPrefix("/") {
                    return .init(tree: XcodeBuildModel.Location.absolute, path: join([path] + components))
                }
                components.insert(path, at: 0)
            }
            switch element.sourceTree ?? .group {
            case .group:
                current = parent(of: element)
            case .absolute:
                return .init(tree: XcodeBuildModel.Location.absolute, path: join(components))
            case .sourceRoot, .none:
                return .init(tree: XcodeBuildModel.Location.sourceRoot, path: join(components))
            case .buildProductsDir:
                return .init(tree: XcodeBuildModel.Location.builtProductsDir, path: join(components))
            case .sdkRoot:
                return .init(tree: XcodeBuildModel.Location.sdkRoot, path: join(components))
            case .developerDir:
                return .init(tree: XcodeBuildModel.Location.developerDir, path: join(components))
            case .custom(let tree):
                return .init(tree: tree, path: join(components))
            }
        }
        // reached the main group
        return .init(tree: XcodeBuildModel.Location.sourceRoot, path: join(components))
    }

    private func join(_ components: [String]) -> String {
        components.joined(separator: "/")
    }

    func fileReference(_ element: PBXFileElement) -> XcodeBuildModel.FileReference {
        if let variantGroup = element as? PBXVariantGroup {
            let variants = variantGroup.children.map(location(of:))
            let base = variants.first { $0.path.contains("Base.lproj/") } ?? variants.first
            let fileType = (variantGroup.children.first as? PBXFileReference).flatMap(fileType)
            return .init(
                location: base ?? location(of: variantGroup),
                fileType: fileType,
                variants: variants
            )
        }
        if let proxy = element as? PBXReferenceProxy {
            return .init(location: location(of: proxy), fileType: proxy.fileType)
        }
        let type = (element as? PBXFileReference).flatMap(fileType)
            ?? (element is PBXGroup ? "group" : nil)
        return .init(location: location(of: element), fileType: type)
    }

    private func fileType(_ reference: PBXFileReference) -> String? {
        reference.explicitFileType ?? reference.lastKnownFileType
    }

    func setting(_ setting: BuildSetting) -> XcodeBuildModel.Setting {
        switch setting {
        case .string(let value): .string(value)
        case .array(let value): .array(value)
        }
    }

    func configuration(_ config: XCBuildConfiguration) -> XcodeBuildModel.Configuration {
        let base: XcodeBuildModel.Location? = if let reference = config.baseConfiguration {
            location(of: reference)
        } else {
            nil
        }
        return .init(
            name: config.name,
            settings: config.buildSettings.mapValues(setting),
            baseConfiguration: base
        )
    }

    func buildFiles(_ phase: PBXBuildPhase) -> [XcodeBuildModel.BuildFile] {
        (phase.files ?? []).compactMap { buildFile in
            guard let file = buildFile.file else { return nil }
            return .init(
                file: fileReference(file),
                compilerFlags: buildFile.settings?["COMPILER_FLAGS"]?.stringValue,
                attributes: buildFile.settings?["ATTRIBUTES"]?.arrayValue ?? []
            )
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    func buildPhase(_ phase: PBXBuildPhase) -> XcodeBuildModel.BuildPhase? {
        switch phase {
        case is PBXSourcesBuildPhase:
            return .sources(buildFiles(phase))
        case is PBXFrameworksBuildPhase:
            return .frameworks(buildFiles(phase))
        case is PBXResourcesBuildPhase:
            return .resources(buildFiles(phase))
        case is PBXHeadersBuildPhase:
            return .headers(buildFiles(phase))
        case let phase as PBXCopyFilesBuildPhase:
            let destination: XcodeBuildModel.CopyFilesPhase.Destination = switch phase.dstSubfolderSpec {
            case .absolutePath: .absolutePath
            case .productsDirectory: .productsDirectory
            case .wrapper: .wrapper
            case .executables: .executables
            case .resources, .javaResources: .resources
            case .frameworks: .frameworks
            case .sharedFrameworks: .sharedFrameworks
            case .sharedSupport: .sharedSupport
            case .plugins: .plugins
            case .other, nil: .other(phase.dstSubfolderSpec?.rawValue ?? 0)
            }
            return .copyFiles(.init(
                name: phase.name,
                destination: destination,
                subpath: phase.dstPath ?? "",
                files: buildFiles(phase),
                deploymentPostprocessingOnly: phase.runOnlyForDeploymentPostprocessing
            ))
        case let phase as PBXShellScriptBuildPhase:
            return .shellScript(.init(
                name: phase.name,
                shellPath: phase.shellPath ?? "/bin/sh",
                script: phase.shellScript ?? "",
                inputPaths: phase.inputPaths,
                outputPaths: phase.outputPaths,
                deploymentPostprocessingOnly: phase.runOnlyForDeploymentPostprocessing
            ))
        default:
            return nil
        }
    }

    func target(_ target: PBXTarget) -> XcodeBuildModel.Target {
        let configList = target.buildConfigurationList
        return .init(
            name: target.name,
            productName: target.productName,
            productType: target.productType?.rawValue ?? "",
            configurations: (configList?.buildConfigurations ?? []).map(configuration),
            defaultConfigurationName: configList?.defaultConfigurationName,
            buildPhases: target.buildPhases.compactMap(buildPhase),
            dependencies: target.dependencies.compactMap { $0.target?.name ?? $0.name },
            isAggregate: target is PBXAggregateTarget
        )
    }
}
