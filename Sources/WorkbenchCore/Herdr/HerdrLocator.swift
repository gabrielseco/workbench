import Foundation

/// Finds the `herdr` executable for the window. A Dock-launched app has a bare `PATH`, so the usual install places are looked in too.
public enum HerdrLocator {
    public static func extraDirectories(home: String) -> [String] {
        ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
    }

    /// What the `herdr` config key may hold: one bare command name or an absolute path, nothing a shell would read.
    public static func valueProblem(_ value: String) -> String? {
        if value.isEmpty || value.count > 500 { return "must be 1 to 500 characters" }
        let shell = "\"'`$&|;<>*?(){}\\".unicodeScalars
        if value.unicodeScalars.contains(where: { $0.value < 0x21 || $0.value == 0x7F || shell.contains($0) }) {
            return "must be one command name or an absolute path, with no spaces, quotes or shell characters"
        }
        if value.contains("/"), !value.hasPrefix("/") { return "must be a command name on PATH or an absolute path" }
        return nil
    }

    /// The configured executable when one is named (and only that one: a stand-in must not be skipped for a real one), else `herdr` on
    /// `PATH`'s absolute entries and then the usual install places. nil when there is none.
    public static func find(configured: String?, searchPath: String?, home: String) -> URL? {
        let absolute = (searchPath ?? "").split(separator: ":").filter { $0.hasPrefix("/") }.map(String.init)
        if let configured { return ExecutableResolver.resolve(configured, searchPath: absolute.joined(separator: ":")) }
        return ExecutableResolver.resolve("herdr", searchPath: (absolute + extraDirectories(home: home)).joined(separator: ":"))
    }
}

extension Config {
    /// The `herdr` key, in the project's config or the global one: the value, or nil after `fail` has been told.
    static func herdrValue(_ value: String, line: Int, fail: ReviewConfig.Fail) -> String? {
        guard let reason = HerdrLocator.valueProblem(value) else { return value }
        fail(.invalidValue, line, "'herdr' \(reason)")
        return nil
    }
}
