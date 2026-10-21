import Foundation

/// `~/.workbench/config.toml`: machine-level defaults for `workbench new`, and the personal `editor` for
/// `workbench open`. It supplies a few keys and nothing else; a project's own `.workbench/config.toml` is still the
/// only thing a run reads, so a global file can never change what an existing project does.
public struct GlobalConfig: Sendable, Equatable {
    public static let allowedKeys: [String] = ["claude_path", "editor", "model", "projects_dir"]

    /// Where `workbench new <name>` puts the project when no location is given. Absolute, `~` expanded.
    public var projectsDirectory: URL?
    public var claudePath: String?
    public var model: String?
    /// What `workbench open` starts when neither `--editor` nor the project names one.
    public var editor: String?

    public init(projectsDirectory: URL? = nil, claudePath: String? = nil, model: String? = nil, editor: String? = nil) {
        self.projectsDirectory = projectsDirectory
        self.claudePath = claudePath
        self.model = model
        self.editor = editor
    }

    /// `~/.workbench/config.toml`, next to where each project keeps its own `.workbench/`.
    public static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let home = environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent(".workbench/config.toml")
    }

    /// An absent file is an empty config. An unreadable or invalid one is an error naming the file.
    public static func load(from url: URL, home: String = NSHomeDirectory()) throws -> GlobalConfig {
        guard FileManager.default.fileExists(atPath: url.path) else { return GlobalConfig() }
        let text: String
        do { text = try String(contentsOf: url, encoding: .utf8) } catch {
            throw ConfigError(problems: [
                ConfigProblem(code: .unreadable, line: nil, message: "cannot read \(url.path): \(error.localizedDescription)")
            ])
        }
        do { return try parse(text, home: home) } catch let error as ConfigError {
            throw ConfigError(
                problems: error.problems.map {
                    ConfigProblem(code: $0.code, line: $0.line, message: "\(url.path): \($0.message)")
                })
        }
    }

    public static func parse(_ text: String, home: String = NSHomeDirectory()) throws -> GlobalConfig {
        let (document, syntaxProblems) = TOMLSubset.parse(text)
        var problems = syntaxProblems
        func fail(_ code: ConfigProblem.Code, _ line: Int?, _ message: String) {
            problems.append(ConfigProblem(code: code, line: line, message: message))
        }

        for (name, table) in document.tables.sorted(by: { $0.key < $1.key }) {
            if name != "" {
                fail(.unknownTable, table.line, "table [\(name)] is not allowed in the global config")
                continue
            }
            for (key, entry) in table.entries.sorted(by: { $0.key < $1.key }) where !allowedKeys.contains(key) {
                fail(
                    .unknownKey, entry.line,
                    "'\(key)' is not allowed in the global config (allowed: \(allowedKeys.joined(separator: ", "))); "
                        + "set it in the project's .workbench/config.toml")
            }
        }

        func string(_ key: String) -> (String, Int)? {
            guard let entry = document.tables[""]?.entries[key] else { return nil }
            guard case .string(let s) = entry.value else {
                fail(.wrongType, entry.line, "'\(key)' must be a string, found \(entry.value.typeName)")
                return nil
            }
            return (s, entry.line)
        }

        var result = GlobalConfig()
        if let (value, line) = string("claude_path") {
            if value.isEmpty || value.contains("\n") || value.contains("\0") {
                fail(.invalidValue, line, "'claude_path' must be a command name or a path")
            } else {
                result.claudePath = value
            }
        }
        if let (value, line) = string("model") {
            if SafeNames.isModelName(value) {
                result.model = value
            } else {
                fail(.invalidValue, line, "'model' must be a model name or alias like \"haiku\"")
            }
        }
        if let (value, line) = string("editor") { result.editor = Config.editorValue(value, line: line, fail: fail) }
        if let (value, line) = string("projects_dir") {
            if let url = expandedDirectory(value, home: home) {
                result.projectsDirectory = url
            } else {
                fail(.invalidValue, line, "'projects_dir' must be an absolute path or start with ~/")
            }
        }

        guard problems.isEmpty else {
            throw ConfigError(
                problems: problems.enumerated().sorted {
                    ($0.element.line ?? .max, $0.offset) < ($1.element.line ?? .max, $1.offset)
                }.map(\.element))
        }
        return result
    }

    /// `~` and `~/x` become the home directory; anything else must already be absolute. nil when it is
    /// neither (a relative path would mean "wherever the command was run", which is the accident to avoid).
    static func expandedDirectory(_ value: String, home: String) -> URL? {
        guard !value.isEmpty, !value.contains("\0"), !value.contains("\n") else { return nil }
        if value == "~" { return URL(fileURLWithPath: home).standardizedFileURL }
        if value.hasPrefix("~/") {
            return URL(fileURLWithPath: home).appendingPathComponent(String(value.dropFirst(2))).standardizedFileURL
        }
        guard value.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: value).standardizedFileURL
    }
}
