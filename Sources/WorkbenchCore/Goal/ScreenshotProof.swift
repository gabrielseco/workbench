import Foundation

/// `proof: screenshot: <name>` is satisfied by `<name>.png` in the latest verify step's proof, shown to a
/// person and never counted as met on its own (docs/spec/goal-file.md).
public enum ScreenshotProof {
    /// The screenshot a proof asks for: nil when the proof is not of this form.
    public static func name(in proof: String) -> String? {
        let trimmed = proof.trimmingCharacters(in: .whitespaces)
        guard let match = trimmed.wholeMatch(of: #/(?i)screenshot:\s*(.+)/#) else { return nil }
        let candidate = String(match.1).trimmingCharacters(in: .whitespaces)
        return isValidName(candidate) ? candidate : nil
    }

    /// One filename-safe token, so a name can only ever pick a file at the top of the proof directory.
    static func isValidName(_ s: String) -> Bool {
        s.wholeMatch(of: #/[A-Za-z0-9][A-Za-z0-9._-]{0,63}/#) != nil
    }

    /// True for a proof that starts `screenshot:` but names nothing usable, which the goal parser refuses.
    public static func isMalformed(_ proof: String) -> Bool {
        let trimmed = proof.trimmingCharacters(in: .whitespaces)
        return trimmed.lowercased().hasPrefix("screenshot:") && name(in: trimmed) == nil
    }

    public static func fileName(for name: String) -> String { "\(name).png" }
}
