import SwiftUI
import WorkbenchCore

/// The goal's request, criteria and out of scope as blocks, with what stops it being approved: changed in place while it is a draft
/// (core's `GoalEditor` writes the file), read-only otherwise. The Goal screen and the feed's goal card both draw these, so neither owns
/// the editor. `editable` is the caller's to decide, from the same rules the Run settings use (`ProjectStore.goalEditable`).
struct GoalBlocks: View {
    /// The Goal screen's form, or the feed's draft goal card (design parity 7): the request in the body face in a bordered box, each
    /// criterion a bordered row with a ring. Used by the feed only.
    enum Style { case classic, feed }

    var goal: GoalModel
    var store: ProjectStore
    var editable: Bool
    var style = Style.classic
    /// The edit error under the blocks: the Goal screen draws it lower down, after its other sections.
    var showsError = false
    @State private var addingCriterion = false
    @State private var addingScope = false
    @State private var showAllRequest = false

    private var mono: Font { .system(.callout, design: .monospaced) }

    /// A read-only request this long is folded; while editing it is shown whole.
    private var longRequest: Bool { goal.request.count > 500 }

    private func edit(_ change: GoalEdit) { Task { await store.editGoal(change) } }

    /// An edit built from the goal as it is when it runs, for a change to a list.
    private func edit(_ make: @escaping @MainActor (GoalModel) -> GoalEdit?) { Task { await store.editGoal(make) } }

    var body: some View {
        VStack(alignment: .leading, spacing: style == .feed ? 18 : 26) {
            if !goal.blockers.isEmpty { blockers }
            if goal.placeholdersRemain {
                Label("Replace every TODO(workbench), then approve.", systemImage: "pencil")
                    .font(.callout).foregroundStyle(Theme.amber)
            }
            request
            criteria
            outOfScope
            if showsError, let error = store.goalEditError {
                Label(error, systemImage: "xmark.octagon.fill").font(.callout).foregroundStyle(Theme.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.goalEditSerial, store.goalEditSerial)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        GoalSection(title: title, content: content)
    }

    private var blockers: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(goal.blockers, id: \.self) {
                Label($0, systemImage: "xmark.octagon.fill").foregroundStyle(Theme.red).font(.callout)
            }
        }
    }

    private var request: some View {
        section("Request") {
            GoalCard(style: style) {
                if editable {
                    if style == .feed {
                        CommitEditor(value: goal.request, font: .body, lineSpacing: 2) { edit(.setRequest($0)) }
                    } else {
                        CommitEditor(value: goal.request) { edit(.setRequest($0)) }
                    }
                } else {
                    Text(goal.request).font(style == .feed ? .body : .system(size: 16, design: .serif))
                        .lineSpacing(style == .feed ? 2 : 5).textSelection(.enabled)
                        .lineLimit(longRequest && !showAllRequest ? 6 : nil)
                    if longRequest {
                        Button(showAllRequest ? "Show less" : "Show more") { showAllRequest.toggle() }
                            .buttonStyle(.borderless).font(.callout)
                    }
                }
            }
        }
    }

    private var criteria: some View {
        section(goal.rows.isEmpty && goal.quick ? "Criteria · none, a quick goal" : "Criteria · \(goal.checkableText)") {
            VStack(alignment: .leading, spacing: 14) {
                if goal.rows.isEmpty && goal.quick {
                    Text(
                        "The request is the goal. With no criteria the judge does not run, the verifier drives the app from the "
                            + "request, and you check the work against it. Add a criterion to have the judge check it."
                    )
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(goal.rows, id: \.id) { row in
                    GoalCard(style: style) { criterion(row) }
                }
                if editable {
                    if addingCriterion {
                        NewCriterionCard { text, proof in
                            edit(.addCriterion(text: text, proof: proof))
                            addingCriterion = false
                        } cancel: { addingCriterion = false }
                    } else {
                        Button("+ criterion") { addingCriterion = true }.buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private func criterion(_ row: GoalModel.Row) -> some View {
        HoverRow { hovering in
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if style == .feed {
                    Circle().strokeBorder(Theme.grey, lineWidth: 1.5).frame(width: 11, height: 11).accessibilityHidden(true)
                } else {
                    Text(row.id).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    if editable {
                        CommitField(placeholder: "What must hold", value: row.text) {
                            edit(.updateCriterion(id: row.id, text: $0, proof: nil))
                        }
                        HStack(spacing: 8) {
                            KindChip(kind: row.kind)
                            CommitField(
                                placeholder: "How it will be shown", value: row.proof, font: row.isCommand ? mono : .callout
                            ) { edit(.updateCriterion(id: row.id, text: nil, proof: $0)) }
                        }
                    } else {
                        Text(row.text)
                        HStack(spacing: 8) {
                            KindChip(kind: row.kind)
                            Text(row.proof).font(row.isCommand ? mono : .callout).foregroundStyle(.secondary)
                        }
                    }
                    if let warning = row.warning {
                        Label("Heads up: \(warning)", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(Theme.amber)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if editable, goal.rows.count > 1 || goal.quick {
                    Spacer()
                    Button { edit(.removeCriterion(id: row.id)) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Remove \(row.id)").opacity(hovering ? 1 : 0.3)
                }
            }
        }
    }

    private var outOfScope: some View {
        section("Out of scope") {
            if !goal.outOfScope.isEmpty || editable {
                GoalCard(style: style) {
                    ForEach(Array(goal.outOfScope.enumerated()), id: \.offset) { _, item in
                        HoverRow { hovering in
                            HStack(spacing: 10) {
                                if editable {
                                    Text("•")
                                    CommitField(placeholder: "What must not change", value: item) { new in
                                        edit { $0.replacingOutOfScope(item, with: new) }
                                    }
                                    Button {
                                        edit { $0.removingOutOfScope(item) }
                                    } label: { Image(systemName: "xmark") }
                                        .buttonStyle(.borderless).help("Remove").opacity(hovering ? 1 : 0.3)
                                } else {
                                    Text("• \(item)")
                                }
                            }
                        }
                    }
                    if editable {
                        if addingScope {
                            NewLine(placeholder: "What must not change") { text in
                                edit { $0.addingOutOfScope(text) }
                                addingScope = false
                            } cancel: { addingScope = false }
                        } else {
                            Button("+ out of scope") { addingScope = true }.buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
    }
}

/// A block with its small-caps heading, as the Goal screen and the feed's goal card both set them.
struct GoalSection<Content: View>: View {
    var title: String
    var content: Content

    init(title: String, @ViewBuilder content: () -> Content) { (self.title, self.content) = (title, content()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
    }
}
