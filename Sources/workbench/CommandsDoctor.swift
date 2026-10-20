import Foundation
import WorkbenchCore

extension Commands {
    static func printVerifier(_ verifier: DoctorVerifier, base: String) {
        let config = verifier.config
        let model = verifier.model ?? "the claude CLI default"
        if let skill = verifier.skill {
            let cut = skill.truncated ? ", cut at \(VerifierSkill.sizeLimit) bytes" : ""
            out("verifier: \(skill.path) at \(base) (\(skill.bytes) bytes, sha256 \(skill.sha256.prefix(12))\(cut))")
        } else {
            out("verifier: \(config.skill)")
        }
        out("  model:  \(model)")
        out("  tools:  \(config.tools.joined(separator: ", "))")
        out("  budget: $\(config.budgetUSD)  timeout: \(config.timeoutMin) min")
        if let problem = verifier.problem { out("  warning: \(problem)") }
        if let missing = verifier.screenRecording { out("  warning: \(missing)") }
    }

    static func printRun(_ run: DoctorRun) {
        out("run: \(run.config.command)")
        switch run.config.ready {
        case .url(let url): out("  ready:  \(url) answers (within \(run.config.readyTimeoutS)s)")
        case .line(let pattern): out("  ready:  a line matching /\(pattern)/ (within \(run.config.readyTimeoutS)s)")
        }
        if let problem = run.problem { out("  warning: \(problem)") }
    }
}
