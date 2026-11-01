import Foundation

/// Where the timer of one project keeps its files. One launchd agent per project: the name is the project's folder and a short hash of its
/// full path, so two projects called the same do not share an agent.
public struct TimerPaths: Sendable, Equatable {
    public let slug: String
    public let label: String
    public let home: URL

    public init(project: Project, home: URL) {
        let folder = project.root.lastPathComponent.lowercased()
        let clean = String(folder.map { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII ? $0 : "-" }.prefix(30))
        let trimmed = clean.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let hash = SHA256.hash(data: Data(project.root.path.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        slug = (trimmed.isEmpty ? "project" : trimmed) + "-" + hash
        label = "com.workbench.task-tick.\(slug)"
        self.home = home
    }

    public var launcherDirectory: URL { home.appendingPathComponent(".workbench/timers/\(slug)", isDirectory: true) }
    public var launcher: URL { launcherDirectory.appendingPathComponent("tick.sh") }
    public var plist: URL { home.appendingPathComponent("Library/LaunchAgents/\(label).plist") }
    public var log: URL { home.appendingPathComponent("Library/Logs/Workbench/task-tick-\(slug).log") }
}

/// The two files the timer writes. Both are made from the project's path and the binary's, which can hold anything a folder name can, so
/// each is quoted for the language it is written in.
public enum TimerFiles {
    public static let minimumInterval = 300
    public static let maximumInterval = 3600
    public static let defaultInterval = 900

    /// `'...'` for a POSIX shell: a quote inside is closed, escaped and reopened.
    static func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func xmlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// launchd has no shell setup, so the launcher borrows the PATH of a login shell: the same node, python3, pnpm, gh, git and claude as a
    /// terminal. It falls back to a plain PATH when that fails.
    public static func launcher(
        project: Project, workbench: URL, label: String, pullMain: Bool
    ) -> String {
        var lines = [
            "#!/bin/sh",
            "# Written by `workbench task timer install` for \(xmlSafeComment(project.root.path)). Run by launchd as \(label).",
            "# Remove it with `workbench task timer remove`.",
            "P=$(/bin/zsh -lic 'printf %s \"$PATH\"' 2>/dev/null | tail -1)",
            "if [ -n \"$P\" ]; then PATH=$P; else PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin\"; fi",
            "export PATH",
            "cd \(shellQuote(project.root.path)) || exit 1",
            "echo \"--- $(date '+%Y-%m-%d %H:%M:%S') tick\"",
        ]
        if pullMain {
            lines += [
                "# A run branches from local main, so keep it current, but only when that is safe: on main and clean.",
                "if [ \"$(git rev-parse --abbrev-ref HEAD)\" = main ] && [ -z \"$(git status --porcelain)\" ]; then",
                "    GIT_TERMINAL_PROMPT=0 git pull --ff-only -q origin main || echo \"note: could not fast-forward main\"",
                "else",
                "    echo \"note: not on main or not clean; main left alone\"",
                "fi",
            ]
        }
        lines += [
            "# caffeinate -i keeps the Mac from idle-sleeping only while the tick runs.",
            "exec /usr/bin/caffeinate -i \(shellQuote(workbench.path)) task tick",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    /// A comment is one line: anything that would end it is replaced.
    static func xmlSafeComment(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    public static func plist(paths: TimerPaths, project: Project, interval: Int) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(xmlEscape(paths.label))</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(xmlEscape(paths.launcher.path))</string>
            </array>
            <key>WorkingDirectory</key>
            <string>\(xmlEscape(project.root.path))</string>
            <key>EnvironmentVariables</key>
            <dict>
                <key>HOME</key>
                <string>\(xmlEscape(paths.home.path))</string>
            </dict>
            <!-- Every so often. Each task's own schedule says what is due; a run missed while asleep happens once on wake. -->
            <key>StartInterval</key>
            <integer>\(interval)</integer>
            <key>RunAtLoad</key>
            <false/>
            <key>StandardOutPath</key>
            <string>\(xmlEscape(paths.log.path))</string>
            <key>StandardErrorPath</key>
            <string>\(xmlEscape(paths.log.path))</string>
        </dict>
        </plist>

        """
    }

    /// The line for a system with no launchd: a crontab entry that does the same.
    public static func cronLine(project: Project, workbench: URL, interval: Int) -> String {
        let minutes = max(1, interval / 60)
        return "*/\(minutes) * * * * cd \(shellQuote(project.root.path)) && \(shellQuote(workbench.path)) task tick"
    }
}
