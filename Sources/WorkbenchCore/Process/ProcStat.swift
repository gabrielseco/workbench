import Foundation

/// The fields of Linux's `/proc/<pid>/stat`. Plain text parsing, kept out of the Linux file so it is tested on macOS too.
enum ProcStat {
    /// The fields after the command name: state, ppid, pgrp, ... in the order `proc(5)` lists them. The command name sits
    /// in parentheses and may itself hold spaces and parentheses, so the split starts after the last `)`.
    static func fields(_ text: String) -> [Substring]? {
        guard let close = text.lastIndex(of: ")") else { return nil }
        return text[text.index(after: close)...].split(separator: " ")
    }

    /// The start time, in clock ticks since boot: field 22 of the file, index 19 after the command name.
    static func startTicks(_ fields: [Substring]) -> UInt64? {
        fields.count > 19 ? UInt64(fields[19]) : nil
    }

    /// The parent pid: field 4, index 1 after the command name.
    static func parent(_ fields: [Substring]) -> pid_t? {
        fields.count > 1 ? pid_t(fields[1]) : nil
    }
}
