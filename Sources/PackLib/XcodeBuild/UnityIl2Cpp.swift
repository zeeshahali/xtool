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
    /// Whether the IL2CPP runtime goes into its own `il2cpp.a` beside the output (`--static-lib-il2-cpp`,
    /// Unity 6.3) instead of into the output library itself.
    public var staticLibIl2Cpp: Bool

    /// Parses the il2cpp invocation from an (already macro-expanded) script, or nil if it isn't one.
    public init?(script: String) {
        // Older exports pass every option on the il2cpp command line. Unity 6.3 builds them up in a
        // bash array instead (`ARGS=(` then one option per line), so fall back to the whole script.
        let invocation: Substring
        if let line = script.split(whereSeparator: \.isNewline).first(where: {
            $0.contains("--compile-cpp") && $0.contains("--generatedcppdir")
        }) {
            invocation = line
        } else if script.contains("--compile-cpp") && script.contains("--generatedcppdir") {
            invocation = Substring(script.split(whereSeparator: \.isNewline).joined(separator: " "))
        } else {
            return nil
        }

        var options: [String: String] = [:]
        for word in XcodeSettings.splitWords(String(invocation)) where word.hasPrefix("--") {
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
        // a bare flag: present with no value
        self.staticLibIl2Cpp = options["static-lib-il2-cpp"] != nil
    }
}

extension TargetBuilder {
    /// Compiles what Unity's il2cpp tool would: the C++ generated from the game's C# into the output
    /// library, and the IL2CPP runtime (libil2cpp, the Boehm GC and zlib) from the sources Unity exports
    /// in `Il2CppOutputProject/IL2CPP`.
    ///
    /// The source groups and their defines follow the build graph Unity's tool writes on a Mac (the
    /// `bee.dag` of a 6000.3 export): every libil2cpp source except the precompiled-header stubs, the
    /// GC as its one amalgamated `extra/gc.c`, and zlib. Unity batches libil2cpp into "lump" files that
    /// only `#include` those sources, so compiling them one by one gives the same objects.
    func compileIl2Cpp(_ script: UnityIl2CppScript) async throws {
        log("Compiling IL2CPP output (Unity's il2cpp tool is replaced by a native build)")
        let sourceDir = url(script.generatedCppDir)
        let il2cppDir = model.sourceRoot.appending(path: "Il2CppOutputProject/IL2CPP")
        guard FileManager.default.fileExists(atPath: sourceDir.path) else {
            throw XcodeProjectBuilder.Errors.missingFile(sourceDir.path)
        }

        let isDebug = (script.configuration ?? settings.string("CONFIGURATION")).lowercased().contains("debug")
        let base = [
            "-target", targetTriple,
            "-isysroot", toolchain.sdk.path,
            "-fmessage-length=0",
            "-Wno-unknown-warning-option",
            "-Qunused-arguments",
            // generated code is noisy; Unity builds it with warnings suppressed too
            "-w",
            isDebug ? "-O0" : "-O3",
            "-g",
            "-fexceptions",
            "-fno-strict-overflow",
            "-ffunction-sections",
            "-fdata-sections",
            "-fvisibility=hidden",
        ] + (isDebug ? [] : ["-DNDEBUG"])

        // shared by the generated code and the runtime, which must agree on them
        var il2cppDefines = [
            "-DBASELIB_INLINE_NAMESPACE=il2cpp_baselib",
            "-DIL2CPP_MONO_DEBUGGER_DISABLED",
            "-DRUNTIME_IL2CPP",
            "-DIL2CPP_ENABLE_WRITE_BARRIERS=1",
        ]
        if targetTriple.hasPrefix("arm64") { il2cppDefines.append("-DTARGET_ARM64") }
        if let slice = script.incrementalGCTimeSlice {
            il2cppDefines.append("-DIL2CPP_INCREMENTAL_TIME_SLICE=\(slice)")
        }
        il2cppDefines += script.additionalDefines.map { "-D\($0)" }

        func includes(_ paths: [String]) -> [String] {
            ([model.sourceRoot] + paths.map { il2cppDir.appending(path: $0) }).flatMap { ["-I", $0.path] }
        }
        let libil2cppIncludes = [
            "libil2cpp/pch", "libil2cpp", "external/baselib/Include",
            "libil2cpp/os/ClassLibraryPAL/brotli/include", "external/baselib/Platforms/IOS/Include",
        ]

        // the game's code
        let gameFlags = il2cppDefines + ["-DHAVE_BDWGC_GC"]
            + ["-I", sourceDir.path] + includes(libil2cppIncludes)
        let generated = try FileManager.default.contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: nil)
            .filter { ["cpp", "c"].contains($0.pathExtension) }
        var gameJobs = il2cppJobs(generated, flags: base + gameFlags, objects: objectsDir.appending(path: "il2cpp"))

        // the runtime
        let runtimeObjects = objectsDir.appending(path: "il2cpp-runtime")
        let runtimeFlags = il2cppDefines + ["-DGC_NOT_DLL", "-DIL2CPP_DEFAULT_DATA_DIR_PATH=Data"]
            + includes(["external/bdwgc/include"] + libil2cppIncludes)
        let libil2cpp = try sources(in: il2cppDir.appending(path: "libil2cpp"), skipping: "pch")
        let gcFlags = [
            "-DGC_NOT_DLL", "-DIL2CPP_ENABLE_WRITE_BARRIERS=1", "-DHAVE_BOEHM_GC", "-DDEFAULT_GC_NAME=\"BDWGC\"",
            "-DALL_INTERIOR_POINTERS=1", "-DGC_GCJ_SUPPORT=1", "-DJAVA_FINALIZATION=1",
            "-DNO_EXECUTE_PERMISSION=1", "-DGC_NO_THREADS_DISCOVERY=1", "-DIGNORE_DYNAMIC_LOADING=1",
            "-DGC_DONT_REGISTER_MAIN_STATIC_DATA=1", "-DGC_VERSION_MAJOR=7", "-DGC_VERSION_MINOR=7",
            "-DGC_VERSION_MICRO=0", "-DGC_THREADS=1", "-DUSE_MMAP=1", "-DUSE_MUNMAP=1",
        ] + (script.incrementalGCTimeSlice.map { ["-DIL2CPP_INCREMENTAL_TIME_SLICE=\($0)"] } ?? [])
            + includes(["external/bdwgc/libatomic_ops/src", "external/bdwgc/include"])
        let gc = ["extra/gc.c", "extra/krait_signal_handler.c"]
            .map { il2cppDir.appending(path: "external/bdwgc/\($0)") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let zlib = try sources(in: il2cppDir.appending(path: "external/zlib"), recursive: false)
        let runtimeJobs = il2cppJobs(libil2cpp, flags: base + runtimeFlags, objects: runtimeObjects)
            + il2cppJobs(gc, flags: base + gcFlags, objects: runtimeObjects)
            + il2cppJobs(zlib, flags: base + includes([]), objects: runtimeObjects)

        for directory in [objectsDir.appending(path: "il2cpp"), runtimeObjects] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let output = url(script.outputPath)
        if !script.staticLibIl2Cpp { gameJobs += runtimeJobs }
        try await runCompileJobs(gameJobs + (script.staticLibIl2Cpp ? runtimeJobs : []))
        try await archive(gameJobs, as: output)
        if script.staticLibIl2Cpp {
            try await archive(runtimeJobs, as: output.deletingLastPathComponent().appending(path: "il2cpp.a"))
        }
    }

    /// One compile job per source, each object named after the source's path so same-named files in
    /// different folders do not collide.
    private func il2cppJobs(_ sources: [URL], flags: [String], objects: URL) -> [CompileJob] {
        sources.sorted { $0.path < $1.path }.map { source in
            let isCxx = ["cpp", "cc", "mm"].contains(source.pathExtension)
            let name = source.path
                .replacingOccurrences(of: model.sourceRoot.path + "/", with: "")
                .replacingOccurrences(of: "/", with: "_")
            let object = objects.appending(path: (name as NSString).deletingPathExtension + ".o")
            let language = isCxx ? ["-x", "c++", "-std=c++17", "-frtti", "-stdlib=libc++"] : ["-x", "c"]
            return CompileJob(
                source: source,
                object: object,
                arguments: language + flags + [
                    "-MMD", "-MF", object.deletingPathExtension().path + ".d",
                    "-c", source.path, "-o", object.path,
                ]
            )
        }
    }

    private func sources(in directory: URL, skipping skipped: String? = nil, recursive: Bool = true) throws -> [URL] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let files: [URL]
        if recursive {
            let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil)
            files = (enumerator?.allObjects as? [URL]) ?? []
        } else {
            files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        }
        let skip = skipped.map { directory.appending(path: $0).path + "/" }
        return files.filter { file in
            ["cpp", "c"].contains(file.pathExtension) && !(skip.map { file.path.hasPrefix($0) } ?? false)
        }
    }

    private func archive(_ jobs: [CompileJob], as output: URL) async throws {
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fileList = tempDir.appending(path: output.deletingPathExtension().lastPathComponent + ".LinkFileList")
        try Data(jobs.map(\.object.path).joined(separator: "\n").utf8).write(to: fileList)
        try? FileManager.default.removeItem(at: output)
        log("Archiving \(output.lastPathComponent)")
        try await runner.run(toolchain.libtool, toolchain.archiveArguments(output: output, fileList: fileList))
    }
}
