import Foundation

/// The "Run Script" phase that Unity (2022.2+) generates for its `GameAssembly` target.
///
/// That script invokes Unity's `il2cpp` tool to compile the C++ generated from
/// the game's C# code into `libGameAssembly.a`. The tool (and the build backend
/// it drives) only runs on macOS, so we compile the generated sources ourselves.
public struct UnityIl2CppScript: Equatable, Sendable {
    public var generatedCppDir: String
    public var outputPath: String
    public var additionalDefines: [String]
    public var incrementalGCTimeSlice: String?
    public var configuration: String?

    /// Parses the il2cpp invocation from an (already macro-expanded) script, or nil if it isn't one.
    public init?(script: String) {
        guard let line = script.split(whereSeparator: \.isNewline).first(where: {
            $0.contains("--compile-cpp") && $0.contains("--generatedcppdir")
        }) else { return nil }

        var options: [String: String] = [:]
        for word in XcodeSettings.splitWords(String(line)) where word.hasPrefix("--") {
            let parts = word.dropFirst(2).split(separator: "=", maxSplits: 1).map(String.init)
            options[parts[0]] = parts.count > 1 ? parts[1] : ""
        }
        guard let generated = options["generatedcppdir"], !generated.isEmpty,
              let output = options["outputpath"], !output.isEmpty
        else { return nil }
        self.generatedCppDir = generated
        self.outputPath = output
        self.additionalDefines = (options["additional-defines"] ?? "")
            .split(separator: ",")
            .map(String.init)
            .filter { !$0.isEmpty }
        self.incrementalGCTimeSlice = options["incremental-g-c-time-slice"].flatMap { $0.isEmpty ? nil : $0 }
        self.configuration = options["configuration"].flatMap { $0.isEmpty ? nil : $0 }
    }
}

extension TargetBuilder {
    func compileIl2Cpp(_ script: UnityIl2CppScript) async throws {
        log("Compiling IL2CPP output (Unity's il2cpp tool is replaced by a native build)")
        let sourceDir = url(script.generatedCppDir)
        let il2cppDir = model.sourceRoot.appending(path: "Il2CppOutputProject/IL2CPP")
        guard FileManager.default.fileExists(atPath: sourceDir.path) else {
            throw XcodeProjectBuilder.Errors.missingFile(sourceDir.path)
        }

        let isDebug = (script.configuration ?? settings.string("CONFIGURATION")).lowercased().contains("debug")
        var common = [
            "-target", targetTriple,
            "-isysroot", toolchain.sdk.path,
            "-fmessage-length=0",
            "-Wno-unknown-warning-option",
            "-Qunused-arguments",
            // generated code is noisy; Unity builds it with warnings suppressed too
            "-w",
            isDebug ? "-O0" : "-O3",
            "-g",
            "-fno-strict-overflow",
            "-fvisibility=hidden",
            "-DBASELIB_INLINE_NAMESPACE=il2cpp_baselib",
            "-DIL2CPP_MONO_DEBUGGER_DISABLED",
            "-DRUNTIME_IL2CPP",
            "-DGC_NOT_DLL",
            "-DHAVE_BDWGC_GC",
            "-DIL2CPP_ENABLE_WRITE_BARRIERS=1",
        ]
        if !isDebug { common.append("-DNDEBUG") }
        if let slice = script.incrementalGCTimeSlice {
            common.append("-DIL2CPP_INCREMENTAL_TIME_SLICE=\(slice)")
        }
        common += script.additionalDefines.map { "-D\($0)" }
        for include in [
            sourceDir,
            il2cppDir.appending(path: "libil2cpp"),
            il2cppDir.appending(path: "libil2cpp/pch"),
            il2cppDir.appending(path: "external/baselib/Include"),
            il2cppDir.appending(path: "external/baselib/Platforms/IOS/Include"),
            il2cppDir.appending(path: "external/bdwgc/include"),
        ] {
            common += ["-I", include.path]
        }

        let objects = objectsDir.appending(path: "il2cpp")
        try FileManager.default.createDirectory(at: objects, withIntermediateDirectories: true)
        let sources = try FileManager.default.contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: nil)
            .filter { ["cpp", "c"].contains($0.pathExtension) }
            .sorted { $0.path < $1.path }
        let jobs = sources.map { source in
            let isCxx = source.pathExtension == "cpp"
            let object = objects.appending(path: source.deletingPathExtension().lastPathComponent + ".o")
            let language = isCxx ? ["-x", "c++", "-std=c++17", "-stdlib=libc++"] : ["-x", "c"]
            return CompileJob(
                source: source,
                object: object,
                arguments: language + common + [
                    "-MMD", "-MF", object.deletingPathExtension().path + ".d",
                    "-c", source.path, "-o", object.path,
                ]
            )
        }
        try await runCompileJobs(jobs)

        let output = url(script.outputPath)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fileList = tempDir.appending(path: "il2cpp.LinkFileList")
        try Data(jobs.map(\.object.path).joined(separator: "\n").utf8).write(to: fileList)
        try? FileManager.default.removeItem(at: output)
        log("Archiving \(output.lastPathComponent)")
        try await runner.run(toolchain.libtool, ["-static", "-o", output.path, "-filelist", fileList.path])
    }
}
