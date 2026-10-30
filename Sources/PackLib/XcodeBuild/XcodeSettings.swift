import Foundation
import XcodeProjects

/// Resolves Xcode build settings across layers (defaults, xcconfig files,
/// project settings, target settings, overrides), including `$(inherited)`
/// and macro expansion.
public struct XcodeSettings: Sendable {
    public typealias Layer = [String: String]

    /// Conditions for conditional settings like `OTHER_LDFLAGS[sdk=iphoneos*]`.
    public struct Conditions: Sendable {
        public var sdk: String
        public var arch: String
        public var config: String

        public init(sdk: String, arch: String, config: String) {
            self.sdk = sdk
            self.arch = arch
            self.config = config
        }
    }

    /// Layers ordered from lowest to highest precedence.
    public private(set) var layers: [Layer]

    public init(layers: [Layer] = []) {
        self.layers = layers
    }

    public mutating func push(_ layer: Layer) {
        layers.append(layer)
    }

    /// Sets a value in the highest-precedence layer.
    public mutating func set(_ key: String, _ value: String) {
        if layers.isEmpty { layers.append([:]) }
        layers[layers.count - 1][key] = value
    }

    /// Flattens a project configuration's settings into a layer, applying conditional settings.
    public static func layer(
        from settings: [String: XcodeBuildModel.Setting],
        conditions: Conditions
    ) -> Layer {
        var plain: Layer = [:]
        var conditional: Layer = [:]
        for (key, value) in settings {
            let string = switch value {
            case .string(let string): string
            case .array(let array): array.map(quoteIfNeeded).joined(separator: " ")
            }
            if let (base, matches) = parseConditionalKey(key, conditions: conditions) {
                if matches { conditional[base] = string }
            } else {
                plain[key] = string
            }
        }
        return plain.merging(conditional) { $1 }
    }

    /// Parses an `.xcconfig` file (following `#include` directives) into a layer.
    public static func layer(
        xcconfig url: URL,
        conditions: Conditions,
        visited: Set<URL> = []
    ) throws -> Layer {
        guard !visited.contains(url) else { return [:] }
        let contents = try String(contentsOf: url, encoding: .utf8)
        var layer: Layer = [:]
        var conditional: Layer = [:]
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            var line = String(rawLine)
            if let comment = line.range(of: "//") {
                line = String(line[..<comment.lowerBound])
            }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#include") {
                let optional = line.hasPrefix("#include?")
                guard let start = line.firstIndex(of: "\""),
                      let end = line.lastIndex(of: "\""),
                      start < end
                else { continue }
                let path = String(line[line.index(after: start)..<end])
                let included = URL(fileURLWithPath: path, relativeTo: url.deletingLastPathComponent())
                    .standardizedFileURL
                if optional && !FileManager.default.fileExists(atPath: included.path) { continue }
                let sublayer = try self.layer(
                    xcconfig: included,
                    conditions: conditions,
                    visited: visited.union([url])
                )
                layer.merge(sublayer) { $1 }
                continue
            }
            // skip over conditions like `[sdk=iphoneos*]`, which contain `=` themselves
            let searchStart = line.lastIndex(of: "]").map { line.index(after: $0) } ?? line.startIndex
            guard let equals = line[searchStart...].firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.hasSuffix(";") { value.removeLast() }
            if let (base, matches) = parseConditionalKey(key, conditions: conditions) {
                if matches { conditional[base] = value }
            } else {
                layer[key] = value
            }
        }
        return layer.merging(conditional) { $1 }
    }

    /// Returns `(baseKey, matches)` if the key is conditional, otherwise nil.
    static func parseConditionalKey(_ key: String, conditions: Conditions) -> (String, Bool)? {
        guard let open = key.firstIndex(of: "[") else { return nil }
        let base = String(key[..<open])
        var matches = true
        var rest = key[open...]
        while rest.first == "[", let close = rest.firstIndex(of: "]") {
            let condition = rest[rest.index(after: rest.startIndex)..<close]
            rest = rest[rest.index(after: close)...]
            let parts = condition.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let actual: String
            switch parts[0] {
            case "sdk": actual = conditions.sdk
            case "arch": actual = conditions.arch
            case "config": actual = conditions.config
            default: continue
            }
            if !globMatch(pattern: parts[1], actual) {
                matches = false
            }
        }
        return (base, matches)
    }

    static func globMatch(pattern: String, _ string: String) -> Bool {
        // only `*` wildcards are used in practice
        let pieces = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        if pieces.count == 1 { return pattern == string }
        var remaining = Substring(string)
        for (index, piece) in pieces.enumerated() {
            if index == 0 {
                guard remaining.hasPrefix(piece) else { return false }
                remaining = remaining.dropFirst(piece.count)
            } else if index == pieces.count - 1 {
                return piece.isEmpty || remaining.hasSuffix(piece)
            } else if let range = remaining.range(of: piece) {
                remaining = remaining[range.upperBound...]
            } else {
                return false
            }
        }
        return true
    }

    static func quoteIfNeeded(_ value: String) -> String {
        guard value.contains(where: { $0 == " " || $0 == "\t" }) else { return value }
        // don't double-quote values that already contain quotes
        if value.contains("\"") { return value }
        return "\"\(value)\""
    }

    // MARK: - Lookup

    /// Whether any layer defines the given key.
    public func isDefined(_ key: String) -> Bool {
        layers.contains { $0[key] != nil }
    }

    /// All keys defined in any layer.
    public var allKeys: Set<String> {
        layers.reduce(into: []) { $0.formUnion($1.keys) }
    }

    /// The fully-expanded string value of a setting.
    public func string(_ key: String) -> String {
        var stack: [String] = []
        return value(key, below: layers.count, stack: &stack)
    }

    /// The fully-expanded value of a setting, split into words like a shell would.
    public func list(_ key: String) -> [String] {
        Self.splitWords(string(key))
    }

    /// Interprets the setting as a boolean (`YES`/`NO`).
    public func bool(_ key: String, default defaultValue: Bool = false) -> Bool {
        switch string(key).uppercased() {
        case "YES", "TRUE", "1": true
        case "NO", "FALSE", "0": false
        default: defaultValue
        }
    }

    /// Expands macros like `$(FOO)` / `${FOO}` / `$FOO` in an arbitrary string.
    public func expand(_ string: String) -> String {
        var stack: [String] = []
        return expand(string, inheritedKey: nil, inheritedLayer: 0, stack: &stack)
    }

    private func value(_ key: String, below limit: Int, stack: inout [String]) -> String {
        guard stack.count < 64, !stack.contains(key + "@\(limit)") else { return "" }
        var index = limit - 1
        while index >= 0 {
            if let raw = layers[index][key] {
                stack.append(key + "@\(limit)")
                defer { stack.removeLast() }
                return expand(raw, inheritedKey: key, inheritedLayer: index, stack: &stack)
            }
            index -= 1
        }
        return ""
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func expand(
        _ string: String,
        inheritedKey: String?,
        inheritedLayer: Int,
        stack: inout [String]
    ) -> String {
        guard string.contains("$") else { return string }
        var result = ""
        var index = string.startIndex
        while index < string.endIndex {
            let char = string[index]
            guard char == "$" else {
                result.append(char)
                index = string.index(after: index)
                continue
            }
            let next = string.index(after: index)
            guard next < string.endIndex else {
                result.append(char)
                break
            }
            let opener = string[next]
            var expression: String
            if opener == "(" || opener == "{" {
                let closer: Character = opener == "(" ? ")" : "}"
                // find matching closer, accounting for nesting
                var depth = 0
                var cursor = string.index(after: next)
                var end: String.Index?
                while cursor < string.endIndex {
                    let current = string[cursor]
                    if current == opener {
                        depth += 1
                    } else if current == closer {
                        if depth == 0 { end = cursor; break }
                        depth -= 1
                    }
                    cursor = string.index(after: cursor)
                }
                guard let end else {
                    result.append(contentsOf: string[index...])
                    break
                }
                expression = String(string[string.index(after: next)..<end])
                index = string.index(after: end)
            } else if opener == "$" {
                result.append("$")
                index = string.index(after: next)
                continue
            } else if opener.isLetter || opener == "_" {
                var cursor = next
                while cursor < string.endIndex, string[cursor].isLetter || string[cursor].isNumber || string[cursor] == "_" {
                    cursor = string.index(after: cursor)
                }
                expression = String(string[next..<cursor])
                index = cursor
            } else {
                result.append(char)
                index = next
                continue
            }

            // nested macros in the expression, e.g. $(FOO_$(CONFIGURATION))
            if expression.contains("$") {
                expression = expand(expression, inheritedKey: inheritedKey, inheritedLayer: inheritedLayer, stack: &stack)
            }

            let parts = expression.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            let name = parts[0]
            var value: String
            if name == "inherited" {
                value = inheritedKey.map { self.value($0, below: inheritedLayer, stack: &stack) } ?? ""
            } else if name == inheritedKey {
                // self-reference behaves like $(inherited)
                value = self.value(name, below: inheritedLayer, stack: &stack)
            } else {
                value = self.value(name, below: layers.count, stack: &stack)
            }
            for op in parts.dropFirst() {
                value = Self.apply(operator: op, to: value)
            }
            result += value
        }
        return result
    }

    // swiftlint:disable:next cyclomatic_complexity
    public static func apply(operator op: String, to value: String) -> String {
        if op.hasPrefix("default=") {
            return value.isEmpty ? String(op.dropFirst("default=".count)) : value
        }
        switch op {
        case "lower": return value.lowercased()
        case "upper": return value.uppercased()
        case "quote": return quoteIfNeeded(value)
        case "base": return ((value as NSString).lastPathComponent as NSString).deletingPathExtension
        case "file": return (value as NSString).lastPathComponent
        case "dir": return (value as NSString).deletingLastPathComponent + "/"
        case "suffix":
            let ext = (value as NSString).pathExtension
            return ext.isEmpty ? "" : ".\(ext)"
        case "standardizepath": return (value as NSString).standardizingPath
        case "rfc1034identifier":
            return String(value.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") ? $0 : "-" })
        case "c99extidentifier", "identifier":
            var mapped = String(value.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") ? $0 : "_" })
            if let first = mapped.first, first.isNumber { mapped = "_" + mapped }
            return mapped
        default: return value
        }
    }

    /// Splits a string into words, honoring single/double quotes and backslash escapes.
    public static func splitWords(_ string: String) -> [String] {
        var words: [String] = []
        var current = ""
        var hasCurrent = false
        var quote: Character?
        var escaping = false
        for char in string {
            if escaping {
                current.append(char)
                escaping = false
                continue
            }
            if char == "\\" && quote != "'" {
                escaping = true
                hasCurrent = true
                continue
            }
            if let activeQuote = quote {
                if char == activeQuote {
                    quote = nil
                } else {
                    current.append(char)
                }
                continue
            }
            if char == "\"" || char == "'" {
                quote = char
                hasCurrent = true
            } else if char == " " || char == "\t" || char == "\n" {
                if hasCurrent {
                    words.append(current)
                    current = ""
                    hasCurrent = false
                }
            } else {
                current.append(char)
                hasCurrent = true
            }
        }
        if hasCurrent { words.append(current) }
        return words
    }
}
