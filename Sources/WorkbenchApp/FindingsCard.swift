import SwiftUI
import WorkbenchCore

/// What the judge and the review steps found wrong, listed under the decision card, so a criterion that was not met is read before the
/// work is accepted. The decision's "Fix findings" sends exactly this to the agent.
struct FindingsCard: View {
    var findings: OpenFindings

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionLabel("FINDINGS")
            ForEach(findings.items) { item in
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(item.title).textStyle(.callout)
                    if let detail = item.detail {
                        Text(detail).role(.caption).lineLimit(item.source == OpenFindings.judgeSource ? 2 : 8)
                    }
                }
            }
        }
        .padding(Space.m).frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
