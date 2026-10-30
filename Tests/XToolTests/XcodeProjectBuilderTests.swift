import Testing
import Foundation
import PackLib
import XcodeProjects

private let fixtureURL = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .appending(path: "Fixtures/UnityLike/Unity-iPhone.xcodeproj")

private let fakeToolchain = XcodeToolchain(
    clang: URL(filePath: "/usr/bin/clang"),
    swiftc: URL(filePath: "/usr/bin/swiftc"),
    linker: nil,
    libtool: URL(filePath: "/usr/bin/libtool"),
    developerDir: URL(filePath: "/Developer"),
    sdk: URL(filePath: "/Developer/SDKs/iPhoneOS26.0.sdk"),
    sdkVersion: "26.0",
    swiftResourceDir: nil
)

private func makeBuilder(
    configuration: String? = nil,
    overrides: [String: String] = [:]
) throws -> XcodeProjectBuilder {
    try XcodeProjectBuilder(
        model: XcodeBuildModel(contentsOf: fixtureURL),
        toolchain: fakeToolchain,
        options: .init(
            configuration: configuration,
            buildDir: URL(filePath: "/tmp/xtool-test-build"),
            overrides: overrides
        ),
        log: { _ in }
    )
}

@Suite struct XcodeSettingsTests {
    let conditions = XcodeSettings.Conditions(sdk: "iphoneos26.0", arch: "arm64", config: "Release")

    @Test func inheritedAndMacroExpansion() {
        var settings = XcodeSettings()
        settings.push(["TARGET_NAME": "Game", "FLAGS": "-a"])
        settings.push(["FLAGS": "$(inherited) -b", "PRODUCT_NAME": "$(TARGET_NAME)"])
        settings.push(["FLAGS": "$(FLAGS) -c", "BUNDLE": "com.example.${PRODUCT_NAME:lower}"])
        #expect(settings.string("FLAGS") == "-a -b -c")
        #expect(settings.list("FLAGS") == ["-a", "-b", "-c"])
        #expect(settings.string("BUNDLE") == "com.example.game")
        #expect(settings.string("MISSING") == "")
        #expect(settings.expand("$(PRODUCT_NAME).app") == "Game.app")
    }

    @Test func operators() {
        #expect(XcodeSettings.apply(operator: "c99extidentifier", to: "Unity-iPhone") == "Unity_iPhone")
        #expect(XcodeSettings.apply(operator: "rfc1034identifier", to: "My Game_1") == "My-Game-1")
        #expect(XcodeSettings.apply(operator: "default=x", to: "") == "x")
        #expect(XcodeSettings.apply(operator: "base", to: "/a/b.txt") == "b")
    }

    @Test func recursionTerminates() {
        var settings = XcodeSettings()
        settings.push(["A": "$(B)", "B": "$(A)"])
        #expect(settings.string("A") == "")
    }

    @Test func conditionalSettings() {
        let layer = XcodeSettings.layer(
            from: [
                "OTHER_LDFLAGS": .string("-lplain"),
                "OTHER_LDFLAGS[sdk=iphoneos*]": .string("-ldevice"),
                "OTHER_LDFLAGS[sdk=iphonesimulator*]": .string("-lsim"),
                "ARCHS[arch=x86_64]": .string("x86_64"),
            ],
            conditions: conditions
        )
        #expect(layer["OTHER_LDFLAGS"] == "-ldevice")
        #expect(layer["ARCHS"] == nil)
    }

    @Test func xcconfig() throws {
        let url = fixtureURL.deletingLastPathComponent().appending(path: "Configs/Shared.xcconfig")
        let layer = try XcodeSettings.layer(xcconfig: url, conditions: conditions)
        #expect(layer["GCC_PREPROCESSOR_DEFINITIONS"] == "FROM_XCCONFIG=1 $(inherited)")
        #expect(layer["OTHER_CFLAGS"] == "-DIOS_DEVICE=1")
    }

    @Test func splitWords() {
        #expect(XcodeSettings.splitWords(#"-I "a b" 'c d' e\ f  g"#) == ["-I", "a b", "c d", "e f", "g"])
        #expect(XcodeSettings.splitWords("").isEmpty)
    }
}

@Suite struct XcodeProjectBuilderTests {
    @Test func parsesModel() throws {
        let model = try XcodeBuildModel(contentsOf: fixtureURL)
        #expect(model.targets.map(\.name) == ["Unity-iPhone", "UnityFramework", "GameLib"])
        #expect(model.defaultConfigurationName == "Release")

        let framework = try #require(model.target(named: "UnityFramework"))
        guard case .sources(let sources) = framework.buildPhases[1] else {
            Issue.record("Expected sources phase")
            return
        }
        #expect(sources.map(\.file.location.path) == ["Classes/Engine.cpp", "Libraries/Plugins/iOS/Plugin.m"])
        #expect(sources[1].compilerFlags == "-fno-objc-arc")

        let app = try #require(model.target(named: "Unity-iPhone"))
        guard case .resources(let resources) = app.buildPhases[1] else {
            Issue.record("Expected resources phase")
            return
        }
        let data = try #require(resources.first)
        #expect(data.file.isFolderReference)
        #expect(data.file.location == .init(tree: "SOURCE_ROOT", path: "Data"))
        let strings = try #require(resources.last)
        #expect(strings.file.variants.map(\.path) == ["en.lproj/InfoPlist.strings"])

        #expect(model.files.contains { $0.location.path == "Libraries/Plugins/iOS/PluginHelper.h" })
    }

    @Test func resolvesSettings() throws {
        let builder = try makeBuilder()
        let model = builder.model
        let framework = try builder.settings(for: try #require(model.target(named: "UnityFramework")))
        #expect(framework.string("FULL_PRODUCT_NAME") == "UnityFramework.framework")
        #expect(framework.string("EXECUTABLE_PATH") == "UnityFramework.framework/UnityFramework")
        #expect(framework.string("LD_DYLIB_INSTALL_NAME") == "@rpath/UnityFramework.framework/UnityFramework")
        #expect(framework.list("GCC_PREPROCESSOR_DEFINITIONS") == ["FROM_XCCONFIG=1", "NDEBUG=1", "RUNTIME_IL2CPP=1"])
        #expect(framework.string("SDKROOT") == fakeToolchain.sdk.path)
        #expect(framework.string("BUILT_PRODUCTS_DIR") == "/tmp/xtool-test-build/Build/Products/Release-iphoneos")

        let lib = try builder.settings(for: try #require(model.target(named: "GameLib")))
        #expect(lib.string("FULL_PRODUCT_NAME") == "libGameLib.a")

        let app = try builder.settings(for: try builder.mainTarget())
        #expect(app.string("PRODUCT_MODULE_NAME") == "Unity_iPhone")
        #expect(app.list("LD_RUNPATH_SEARCH_PATHS") == ["@executable_path/Frameworks"])
    }

    @Test func overridesAndConfigurations() throws {
        let builder = try makeBuilder(
            configuration: "Debug",
            overrides: ["PRODUCT_BUNDLE_IDENTIFIER": "com.override.game"]
        )
        let app = try builder.settings(for: try builder.mainTarget())
        #expect(app.string("PRODUCT_BUNDLE_IDENTIFIER") == "com.override.game")
        #expect(app.string("CONFIGURATION") == "Debug")
        #expect(app.string("GCC_OPTIMIZATION_LEVEL") == "0")
    }

    @Test func buildOrderIncludesImplicitDependencies() throws {
        let builder = try makeBuilder()
        // GameLib is only linked by UnityFramework (no explicit dependency)
        let order = try builder.buildOrder(for: try builder.mainTarget())
        #expect(order.map(\.name) == ["GameLib", "UnityFramework", "Unity-iPhone"])
    }

    @Test func unknownTarget() throws {
        let builder = try XcodeProjectBuilder(
            model: XcodeBuildModel(contentsOf: fixtureURL),
            toolchain: fakeToolchain,
            options: .init(target: "Nope", buildDir: URL(filePath: "/tmp")),
            log: { _ in }
        )
        #expect(throws: XcodeProjectBuilder.Errors.self) { try builder.mainTarget() }
    }

    @Test func filtersAppleOnlyLinkerFlags() {
        #expect(
            XcodeProjectBuilder.filterLinkerFlags(["-ld64", "-ObjC", "-Xlinker", "-ld_classic", "-Wl,-ld_classic", "-lz"])
                == ["-ObjC", "-lz"]
        )
    }

    @Test func stripsLikeAnXcodeArchive() {
        func flags(_ values: [String: String]) -> [String] {
            var settings = XcodeSettings()
            settings.push(values)
            return XcodeProjectBuilder.stripLinkerFlags(settings)
        }
        #expect(flags([:]) == ["-Xlinker", "-S", "-Xlinker", "-x"])
        #expect(flags(["STRIP_STYLE": "non-global"]) == ["-Xlinker", "-S", "-Xlinker", "-x"])
        #expect(flags(["STRIP_STYLE": "debugging"]) == ["-Xlinker", "-S"])
        #expect(flags(["STRIP_INSTALLED_PRODUCT": "NO"]).isEmpty)
        #expect(flags(["DEPLOYMENT_POSTPROCESSING": "NO"]).isEmpty)
    }

    @Test func stripsInPlaceWithStripOrObjcopy() {
        func toolchain(_ strip: String) -> XcodeToolchain {
            XcodeToolchain(
                clang: URL(fileURLWithPath: "/bin/clang"), swiftc: URL(fileURLWithPath: "/bin/swiftc"),
                linker: nil, libtool: URL(fileURLWithPath: "/bin/libtool"),
                developerDir: URL(fileURLWithPath: "/dev"), sdk: URL(fileURLWithPath: "/sdk"),
                sdkVersion: "27.2", swiftResourceDir: nil, strip: URL(fileURLWithPath: strip)
            )
        }
        let binary = URL(fileURLWithPath: "/out/Game")
        #expect(toolchain("/bin/llvm-objcopy").stripArguments(.nonGlobal, binary: binary)
            == ["--strip-debug", "--discard-all", "/out/Game"])
        #expect(toolchain("/bin/llvm-objcopy").stripArguments(.debugging, binary: binary)
            == ["--strip-debug", "/out/Game"])
        #expect(toolchain("/usr/bin/strip").stripArguments(.nonGlobal, binary: binary) == ["-S", "-x", "/out/Game"])
    }

    @Test func parsesUnityIl2CppScript() throws {
        // abridged from the GameAssembly "Run Script" phase Unity 2022.2+ generates
        let script = #"""
        IL2CPP="/proj/Il2CppOutputProject/IL2CPP/build/deploy_arm64/il2cpp"
        chmod +x "$IL2CPP"
        "$IL2CPP" --compile-cpp --platform=iOS --additional-defines=IL2CPP_DEBUG=0,FOO=1 \
        --incremental-g-c-time-slice=3 --generatedcppdir="Il2CppOutputProject/Source/il2cppOutput" \
        --outputpath="/build/Release-iphoneos/libGameAssembly.a" --configuration=Release \
        --external-lib-il2-cpp="/proj/Libraries/libil2cpp.a"
        """#.replacingOccurrences(of: "\\\n", with: "")
        let parsed = try #require(UnityIl2CppScript(script: script))
        #expect(parsed.generatedCppDir == "Il2CppOutputProject/Source/il2cppOutput")
        #expect(parsed.outputPath == "/build/Release-iphoneos/libGameAssembly.a")
        #expect(parsed.additionalDefines == ["IL2CPP_DEBUG=0", "FOO=1"])
        #expect(parsed.incrementalGCTimeSlice == "3")
        #expect(parsed.configuration == "Release")
        #expect(!parsed.staticLibIl2Cpp)
        #expect(parsed.externalLibIl2Cpp == "/proj/Libraries/libil2cpp.a")
        #expect(UnityIl2CppScript(script: "echo hello") == nil)
    }

    @Test func archivesWithLlvmArWhenThereIsNoLibtool() {
        func toolchain(_ archiver: String) -> XcodeToolchain {
            XcodeToolchain(
                clang: URL(fileURLWithPath: "/bin/clang"), swiftc: URL(fileURLWithPath: "/bin/swiftc"),
                linker: nil, libtool: URL(fileURLWithPath: archiver),
                developerDir: URL(fileURLWithPath: "/dev"), sdk: URL(fileURLWithPath: "/sdk"),
                sdkVersion: "27.2", swiftResourceDir: nil
            )
        }
        let output = URL(fileURLWithPath: "/out/libGameAssembly.a")
        let list = URL(fileURLWithPath: "/tmp/il2cpp.LinkFileList")
        #expect(toolchain("/usr/bin/llvm-ar").archiveArguments(output: output, fileList: list)
            == ["rcs", "--format=darwin", "/out/libGameAssembly.a", "@/tmp/il2cpp.LinkFileList"])
        #expect(toolchain("/toolset/bin/libtool").archiveArguments(output: output, fileList: list)
            == ["-static", "-o", "/out/libGameAssembly.a", "-filelist", "/tmp/il2cpp.LinkFileList"])
    }

    @Test func parsesUnity63Il2CppArgsArray() throws {
        // abridged from Unity 6000.3: the options are a bash array, one per line, expanded at the call
        let script = #"""
        IL2CPP="/proj/Il2CppOutputProject/IL2CPP/build/deploy_x86_64/il2cpp"
        ARGS=(
            --compile-cpp
            --platform=iOS
            --incremental-g-c-time-slice=3
            --static-lib-il2-cpp
            --generatedcppdir="Il2CppOutputProject/Source/il2cppOutput"
            --outputpath="/build/Release-iphoneos/libGameAssembly.a"
            --configuration=""
            )
        "$IL2CPP" "${ARGS[@]}"
        """#
        let parsed = try #require(UnityIl2CppScript(script: script))
        #expect(parsed.generatedCppDir == "Il2CppOutputProject/Source/il2cppOutput")
        #expect(parsed.outputPath == "/build/Release-iphoneos/libGameAssembly.a")
        #expect(parsed.incrementalGCTimeSlice == "3")
        #expect(parsed.configuration == nil)
        #expect(parsed.staticLibIl2Cpp)
    }

    /// Builds the fixture end-to-end. Requires a Darwin SDK (`xtool setup`) on Linux, or Xcode on macOS.
    @Test(.enabled(if: XcodeProjectBuilderTests.hasToolchain))
    func buildsUnityLikeProject() async throws {
        let workDir = FileManager.default.temporaryDirectory.appending(path: "xtool-xcodebuild-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let projectDir = workDir.appending(path: "UnityLike")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtureURL.deletingLastPathComponent(), to: projectDir)

        let builder = try XcodeProjectBuilder(
            model: XcodeBuildModel(contentsOf: projectDir.appending(path: "Unity-iPhone.xcodeproj")),
            toolchain: await XcodeToolchain.current(),
            options: .init(buildDir: workDir.appending(path: "build"), runScripts: true),
            log: { _ in }
        )
        let product = try await builder.build()
        let app = product.url
        #expect(app.lastPathComponent == "Unity-iPhone.app")

        func exists(_ path: String) -> Bool {
            FileManager.default.fileExists(atPath: app.appending(path: path).path)
        }
        #expect(exists("Unity-iPhone"))
        #expect(exists("Frameworks/UnityFramework.framework/UnityFramework"))
        #expect(!exists("Frameworks/UnityFramework.framework/Headers"))
        #expect(exists("Data/data.unity3d"))
        #expect(exists("Data/Managed/Assembly-CSharp.dll"))
        #expect(exists("en.lproj/InfoPlist.strings"))
        #expect(exists("AppIcon60x60@2x.png"))

        let plistData = try Data(contentsOf: app.appending(path: "Info.plist"))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        )
        #expect(plist["CFBundleIdentifier"] as? String == "com.example.unitylike")
        #expect(plist["CFBundleExecutable"] as? String == "Unity-iPhone")
        #expect(plist["MinimumOSVersion"] as? String == "13.0")
        #expect(plist["UIDeviceFamily"] as? [Int] == [1, 2])
        #expect(plist["UILaunchStoryboardName~iphone"] == nil)
        #expect(plist["UILaunchScreen"] != nil)
    }

    static var hasToolchain: Bool {
        #if os(macOS)
        FileManager.default.fileExists(atPath: "/usr/bin/xcrun")
        #else
        (try? DarwinSDK.current()) != nil
        #endif
    }
}
