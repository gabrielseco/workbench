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

    /// A read-only request this long is folded; while editing it is shown whole.
    private var longRequest: Bool { goal.request.count > 500 }

    private func edit(_ change: GoalEdit) { Task { await store.editGoal(change) } }

    /// An edit built from the goal as it is when it runs, for a change to a list.
    private func edit(_ make: @escaping @MainActor (GoalModel) -> GoalEdit?) { Task { await store.editGoal(make) } }

    var body: some View {
        VStack(alignment: .leading, spacing: style == .feed ? Space.xl : Space.xxl) {
            if !goal.blockers.isEmpty { blockers }
            if goal.placeholdersRemain {
                Label("Replace every TODO(workbench), then approve.", systemImage: "pencil")
                    .textRole(.warning)
            }
            request
            criteria
            outOfScope
            if showsError, let error = store.goalEditError {
                Label(error, systemImage: "xmark.octagon.fill").textRole(.error)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.goalEditSerial, store.goalEditSerial)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        GoalSection(title: title, content: content)
    }

    private var blockers: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            ForEach(goal.blockers, id: \.self) {
                Label($0, systemImage: "xmark.octagon.fill").foregroundStyle(Theme.red).textStyle(.callout)
            }
        }
    }

    private var request: some View {
        section("Request") {
            GoalCard(style: style) {
                if editable {
                    if style == .feed {
                        CommitEditor(value: goal.request, style: .body, lineSpacing: 2) { edit(.setRequest($0)) }
                    } else {
                        CommitEditor(value: goal.request) { edit(.setRequest($0)) }
                    }
                } else {
                    Text(goal.request).textStyle(style == .feed ? .body : .serifBody)
                        .lineSpacing(style == .feed ? 2 : 5).textSelection(.enabled)
                        .lineLimit(longRequest && !showAllRequest ? 6 : nil)
                    if longRequest {
                        Button(showAllRequest ? "Show less" : "Show more") { showAllRequest.toggle() }
                            .buttonStyle(.borderless).textStyle(.callout)
                    }
                }
            }
        }
    }

    private var criteria: some View {
        section(criteriaHeading) {
            VStack(alignment: .leading, spacing: Space.l) {
                if goal.rows.isEmpty && goal.quick {
                    Text(
                        "The request is the goal. With no criteria the judge does not run, the verifier drives the app from the "
                            + "request, and you check the work against it. Add a criterion to have the judge check it."
                    )
                    .role(.detail).fixedSize(horizontal: false, vertical: true)
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

    /// The artboard's `Criteria · 5` in the feed while every one can be checked; the Goal screen's `1 of 3 checkable` always, and in the
    /// feed too when some cannot, since that is what the person has to act on.
    private var criteriaHeading: String {
        if goal.rows.isEmpty && goal.quick { return "Criteria · none, a quick goal" }
        if style == .feed && goal.checkable == goal.rows.count { return "Criteria · \(goal.rows.count)" }
        return "Criteria · \(goal.checkableText)"
    }

    private func criterion(_ row: GoalModel.Row) -> some View {
        HoverRow { hovering in
            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                if style == .feed {
                    Circle().strokeBorder(Theme.grey, lineWidth: 1.5).frame(width: 11, height: 11).accessibilityHidden(true)
                } else {
                    Text(row.id).role(.monoDetail)
                }
                VStack(alignment: .leading, spacing: Space.s) {
                    if editable {
                        CommitField(placeholder: "What must hold", value: row.text) {
                            edit(.updateCriterion(id: row.id, text: $0, proof: nil))
                        }
                        HStack(spacing: Space.s) {
                            KindChip(kind: row.kind)
                            CommitField(
                                placeholder: "How it will be shown", value: row.proof,
                                style: row.isCommand ? .monoCallout : .callout
                            ) { edit(.updateCriterion(id: row.id, text: nil, proof: $0)) }
                        }
                    } else {
                        Text(row.text)
                        HStack(spacing: Space.s) {
                            KindChip(kind: row.kind)
                            Text(row.proof).textStyle(row.isCommand ? .monoCallout : .callout, .secondary)
                        }
                    }
                    if let warning = row.warning {
                        Label("Heads up: \(warning)", systemImage: "exclamationmark.triangle.fill")
                            .textRole(.warning)
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
                            HStack(spacing: Space.m) {
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
        VStack(alignment: .leading, spacing: Space.m) {
            Text(title.uppercased()).textStyle(.captionStrong, .secondary)
            content
        }
    }
}
