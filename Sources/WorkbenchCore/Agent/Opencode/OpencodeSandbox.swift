import Foundation

/// The macOS `sandbox-exec` profile an OpenCode coding turn runs inside. OpenCode has no sandbox and its `bash` rules match command text,
/// so the process around it is what confines the shell (`docs/plan/P28-capabilities.md`, task 1b): with every OpenCode rule set to
/// allow, this profile stopped writes outside the worktree (through a tool, the shell, a symlink, `cp`, `python3 -c`), `git commit`,
/// `git push` in every wrapped form, and network from the shell.
///
/// - Writes go to the worktree, the turn's scratch directory and OpenCode's own state directory, nothing else, and not under the
///   worktree's `.git`. A linked worktree's `.git` is a file into the base checkout, which is outside the profile, so a commit fails
///   there too: `accept` commits what is pending, as for Codex.
/// - The network is loopback only. Seatbelt cannot allow a host (`host must be * or localhost`), so the model is reached through a
///   forwarder on loopback. Binding a loopback port is needed too, or OpenCode's standalone server dies unexplained.
/// - macOS tools ignore `TMPDIR` and use the `confstr` temp and cache directories; a narrow allow for the names they create lets
///   `swift build` and `swift test` run. Any other file in those shared directories stays unwritable.
/// - Reads are not confined (the system's libraries are read everywhere); `denyReads` names directories that hold credentials.
///   A sandboxed shell can still reach any other loopback port.
public enum OpencodeSandbox {
    /// The two per-user directories macOS hands out: `getconf DARWIN_USER_TEMP_DIR` and `DARWIN_USER_CACHE_DIR`.
    public struct UserDirectories: Sendable, Equatable {
        public var temp: URL
        public var cache: URL
        public init(temp: URL, cache: URL) {
            self.temp = temp
            self.cache = cache
        }
    }

    /// The directories as the kernel names them (symlinks resolved: seatbelt matches real paths, and `/var` is `/private/var`).
    /// Nil where the system has none (not macOS).
    public static func userDirectories() -> UserDirectories? {
        #if os(macOS)
            func read(_ name: Int32) -> URL? {
                var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
                guard confstr(name, &buffer, buffer.count) > 0, let real = realpath(buffer, nil) else { return nil }
                defer { free(real) }
                return URL(fileURLWithPath: String(cString: real), isDirectory: true)
            }
            guard let temp = read(Int32(_CS_DARWIN_USER_TEMP_DIR)), let cache = read(Int32(_CS_DARWIN_USER_CACHE_DIR)) else {
                return nil
            }
            return UserDirectories(temp: temp, cache: cache)
        #else
            return nil
        #endif
    }

    /// Directories under the home directory that hold credentials or another agent's login. Reading is otherwise allowed, so these are
    /// named; the person's own OpenCode setup is among them (its auth file and service password).
    public static func credentialDirectories(home: URL) -> [URL] {
        [
            ".ssh", ".aws", ".gnupg", ".kube", ".docker", ".netrc", ".npmrc", ".config/gh", ".config/gcloud", ".config/opencode",
            ".local/share/opencode", ".claude", ".claude.json", ".codex",
        ].map { home.appendingPathComponent($0) }
    }

    /// The profile text. Every path must be absolute and already resolved: a path with a quote, a backslash or a control character is
    /// refused, because it would end the string in the profile.
    public static func profile(
        worktree: URL, scratch: URL, state: URL, user: UserDirectories, denyReads: [URL] = []
    ) throws -> String {
        let writable = try [worktree, scratch, state].map { "(subpath \(try quoted($0)))" }.joined(separator: " ")
        let temp = try plain(user.temp), cache = try plain(user.cache)
        // The names macOS tools create in the shared temp directory: the `xcrun` cache, `mktemp -d`, and Foundation's atomic-write
        // staging directory.
        let tempNames = #"^\#(regexEscaped(temp))/(xcrun_db|xcrun_db-|tmp\.)[^/]*"#
        var lines = [
            "(version 1)",
            "(allow default)",
            "(deny file-write*)",
            "(allow file-write* \(writable) (literal \"/dev/null\") (literal \"/dev/tty\") (regex #\"^/dev/ttys\"))",
            "(allow file-write* (regex #\"\(tempNames)\") (subpath \"\(temp)/TemporaryItems\")"
                + " (subpath \"\(cache)/clang/ModuleCache\"))",
            // After the allow above: the last matching rule wins.
            "(deny file-write* (subpath \"\(try plain(worktree))/.git\") (literal \"\(try plain(worktree))/.git\"))",
            "(deny network*)",
            "(allow network* (remote ip \"localhost:*\"))",
            "(allow network-bind (local ip \"localhost:*\"))",
            "(allow network-inbound (local ip \"localhost:*\"))",
        ]
        for dir in denyReads { lines.append("(deny file-read* (subpath \(try quoted(dir))))") }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func plain(_ url: URL) throws -> String {
        let path = url.path
        guard path.hasPrefix("/"), path.count > 1 else {
            throw OpencodeSetupError("The sandbox path \"\(path)\" is not absolute.")
        }
        let bad = path.unicodeScalars.contains { $0 == "\"" || $0 == "\\" || $0.value < 0x20 || $0.value == 0x7F }
        guard !bad else {
            throw OpencodeSetupError("The sandbox path \(path.debugDescription) has a quote, a backslash or a control character.")
        }
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func quoted(_ url: URL) throws -> String { "\"\(try plain(url))\"" }

    /// A path inside a profile's regex: every character that means something to it is escaped.
    static func regexEscaped(_ path: String) -> String {
        var out = ""
        for ch in path {
            if "\\.^$*+?()[]{}|".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }
}
