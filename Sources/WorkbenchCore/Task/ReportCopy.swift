import Foundation

/// The copy of a report in a folder the person reads from (an Obsidian vault is a folder of Markdown files): `<folder>/<task>/<date time>.md`,
/// with front matter a vault shows as properties. Extra to the report under `.workbench/`, never instead of it.
enum ReportCopy {
    /// `reports_copy_to` as a folder: absolute or `~/…`, nothing else (a relative path would depend on where `workbench` was started).
    static func folder(_ value: String) -> URL? {
        guard !value.isEmpty, !value.contains("\0"), !value.contains("\n") else { return nil }
        if value == "~" || value.hasPrefix("~/") {
            return URL(fileURLWithPath: NSString(string: value).expandingTildeInPath, isDirectory: true)
        }
        return value.hasPrefix("/") ? URL(fileURLWithPath: value, isDirectory: true) : nil
    }

    @discardableResult
    static func copy(report: String, task: String, to target: String, at date: Date, calendar: Calendar) throws -> URL {
        guard let root = folder(target) else { throw CocoaError(.fileWriteInvalidFileName) }
        // A task name is already validated (SafeNames); the folder is one level below the vault folder.
        let folder = root.appendingPathComponent(task, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.dateFormat = "yyyy-MM-dd HHmm"
        let stem = format.string(from: date)
        format.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let front = "---\ntask: \(task)\ndate: \(format.string(from: date))\ntags: [workbench-report]\n---\n\n"
        var url = folder.appendingPathComponent("\(stem).md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(stem)-\(n).md")
            n += 1
        }
        try Data((front + report + "\n").utf8).write(to: url, options: .withoutOverwriting)
        return url
    }
}
