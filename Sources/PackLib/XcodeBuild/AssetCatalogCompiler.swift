import Foundation

/// A minimal, portable stand-in for `actool`.
///
/// Apple's asset catalog compiler only runs on macOS, so we can't produce
/// an `Assets.car`. Instead we extract the app icon into loose PNG files and
/// reference them via `CFBundleIcons`, which iOS still supports.
struct AssetCatalogCompiler {
    struct Output {
        /// Info.plist keys to merge into the product's Info.plist.
        var infoPlist: [String: Any] = [:]
        /// Asset names that could not be compiled.
        var skipped: [String] = []
    }

    private struct IconContents: Decodable {
        struct Image: Decodable {
            var filename: String?
            var idiom: String?
            var size: String?
            var scale: String?
            var platform: String?
        }
        var images: [Image]?
    }

    var appIconName: String

    func compile(catalogs: [URL], into bundle: URL) throws -> Output {
        var output = Output()
        var iphoneIcons: [String] = []
        var ipadIcons: [String] = []

        for catalog in catalogs {
            let entries = FileManager.default.enumerator(at: catalog, includingPropertiesForKeys: nil)
            while let entry = entries?.nextObject() as? URL {
                let ext = entry.pathExtension
                guard !ext.isEmpty, ext != "json" else { continue }
                // only look at asset sets, not folders inside them
                guard entry.lastPathComponent.contains(".") else { continue }
                let name = entry.deletingPathExtension().lastPathComponent
                guard ext == "appiconset", name == appIconName else {
                    if ["imageset", "launchimage", "colorset", "dataset", "appiconset",
                        "symbolset", "brandassets", "imagestack", "textureset"].contains(ext) {
                        output.skipped.append(entry.lastPathComponent)
                        entries?.skipDescendants()
                    }
                    continue
                }
                entries?.skipDescendants()
                let (iphone, ipad) = try compileAppIcon(at: entry, into: bundle)
                iphoneIcons += iphone
                ipadIcons += ipad
            }
        }

        if !iphoneIcons.isEmpty || !ipadIcons.isEmpty {
            func icons(_ files: [String]) -> [String: Any] {
                [
                    "CFBundlePrimaryIcon": [
                        "CFBundleIconFiles": Array(NSOrderedSet(array: files)) as? [String] ?? files,
                        "CFBundleIconName": appIconName,
                    ] as [String: Any],
                ]
            }
            output.infoPlist["CFBundleIcons"] = icons(iphoneIcons.isEmpty ? ipadIcons : iphoneIcons)
            output.infoPlist["CFBundleIcons~ipad"] = icons(iphoneIcons + ipadIcons)
        }
        return output
    }

    /// Copies the icon images into the bundle, returning the base names for iPhone and iPad.
    private func compileAppIcon(at set: URL, into bundle: URL) throws -> ([String], [String]) {
        let data = try Data(contentsOf: set.appending(path: "Contents.json"))
        let contents = try JSONDecoder().decode(IconContents.self, from: data)
        var iphone: [String] = []
        var ipad: [String] = []

        func copy(_ source: URL, to name: String) throws {
            let destination = bundle.appending(path: name)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: source, to: destination)
        }

        for image in contents.images ?? [] {
            guard let filename = image.filename else { continue }
            let source = set.appending(path: filename)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let size = image.size ?? "1024x1024"
            let scale = image.scale.map { $0 == "1x" ? "" : "@\($0)" } ?? ""
            let base = "\(appIconName)\(size)"
            switch image.idiom {
            case "iphone":
                try copy(source, to: "\(base)\(scale).png")
                iphone.append(base)
            case "ipad":
                try copy(source, to: "\(base)\(scale)~ipad.png")
                ipad.append(base)
            case "universal" where image.platform == nil || image.platform == "ios":
                // single-size (1024pt) icon: let iOS scale it down
                try copy(source, to: "\(appIconName)60x60@2x.png")
                try copy(source, to: "\(appIconName)76x76@2x~ipad.png")
                iphone.append("\(appIconName)60x60")
                ipad.append("\(appIconName)76x76")
            default:
                // ios-marketing, watch, car, etc. aren't needed on device
                continue
            }
        }
        return (iphone, ipad)
    }
}
