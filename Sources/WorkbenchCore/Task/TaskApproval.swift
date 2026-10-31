import Foundation

/// The consent behind an unattended run. The hash covers the task's settings and instructions and the `pending` script, because both run
/// without anyone watching; the input files are data and are not part of it, so a new list does not need a new approval.
public enum TaskApproval {
    static let version = "workbench-task-v1"

    /// Made from what the task means, not how the file is laid out: the settings, the instructions with their
    /// whitespace normalised, and the script's bytes. Reordering keys, a blank line or a trailing space does not revoke
    /// an approval; any change to a setting, a word of the instructions or the script does.
    public static func hash(task: TaskDefinition, pendingScript: Data?) -> String {
        var fields = [
            version, "schedule=\(task.schedule?.summary ?? "none")", "batch=\(task.batch)", "fix=\(task.fix.rawValue)",
            "budget=\(task.budgetUSD.map { NSDecimalNumber(decimal: $0).stringValue } ?? "none")",
            "include=\(task.include ?? "none")", "pending=\(task.pending ?? "none")",
            "inputs=\(task.inputs.sorted().joined(separator: ","))",
        ]
        if let pendingScript {
            fields.append("pending_sha256=" + SHA256.hash(data: pendingScript).map { String(format: "%02x", $0) }.joined())
        }
        fields += ["---", GoalHash.canonicalBody(task.instructions)]
        return SHA256.hash(data: Data(fields.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public enum State: Equatable, Sendable {
        case never
        /// The file or the script changed since it was approved.
        case stale
        case approved
    }

    public static func state(approvedHash: String?, currentHash: String) -> State {
        guard let approvedHash else { return .never }
        return approvedHash == currentHash ? .approved : .stale
    }
}
