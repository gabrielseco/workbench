import Foundation

/// `proof: screenshot: <name>[, <name>…]` is satisfied by `<name>.png` for every name in the latest turn's proof (what
/// the verifier left), shown to a person and never counted as met on its own
/// (docs/spec/goal-file.md).
public enum ScreenshotProof {
    /// Most names one criterion may list.
    public static let maxNames = 16

    /// The screenshots a proof asks for, in order and without repeats: nil when the proof is not of this form, or a
    /// name is not usable.
    public static func names(in proof: String) -> [String]? {
        let trimmed = proof.trimmingCharacters(in: .whitespaces)
        guard let match = trimmed.wholeMatch(of: #/(?i)screenshot:\s*(.+)/#) else { return nil }
        var names: [String] = []
        for part in String(match.1).split(separator: ",", omittingEmptySubsequences: false) {
            let candidate = part.trimmingCharacters(in: .whitespaces)
            guard isValidName(candidate) else { return nil }
            if !names.contains(candidate) { names.append(candidate) }
        }
        return names.isEmpty || names.count > maxNames ? nil : names
    }

    /// The first screenshot a proof asks for: nil when the proof is not of this form.
    public static func name(in proof: String) -> String? { names(in: proof)?.first }

    /// One filename-safe token, so a name can only ever pick a file at the top of the proof directory.
    static func isValidName(_ s: String) -> Bool {
        s.wholeMatch(of: #/[A-Za-z0-9][A-Za-z0-9._-]{0,63}/#) != nil
    }

    /// True for a proof that starts `screenshot:` but names nothing usable, which the goal parser refuses.
    public static func isMalformed(_ proof: String) -> Bool {
        let trimmed = proof.trimmingCharacters(in: .whitespaces)
        return trimmed.lowercased().hasPrefix("screenshot:") && names(in: trimmed) == nil
    }

    public static func fileName(for name: String) -> String { "\(name).png" }
}
