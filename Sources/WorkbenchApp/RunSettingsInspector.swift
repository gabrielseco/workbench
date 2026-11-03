import SwiftUI
import WorkbenchCore

/// Where the inspector goes. Beside the feed it takes 300 of the centre column, so a window that leaves the feed less than a usable
/// width (the 900×600 minimum does) shows it over the feed, as a sheet, instead.
enum RunSettingsLayout {
    static let width: CGFloat = 300
    /// The centre column's width from which the inspector sits beside the feed (300 for it and at least 600 for the feed): a window about 1150 wide.
    static let besideFrom: CGFloat = 900

    enum Placement: Equatable { case beside, sheet }

    /// Whether the thread has a worktree with the run's changes (its step menu then offers to open it): from the first turn until it
    /// is discarded or cleaned.
    static func hasWorktree(_ state: ThreadState) -> Bool {
        state.lastTurn > 0 && state.decision != "discarded" && !state.cleaned
    }

    static func placement(centreWidth: CGFloat) -> Placement { centreWidth >= besideFrom ? .beside : .sheet }

    /// What the header's button sets: what is on screen is turned off, what is not is turned on. The default is on, but in a window too
    /// narrow to hold it beside the feed it shows nothing until a person has chosen, so the first click there opens it.
    static func toggled(on: Bool, chosen: Bool, fits: Bool) -> Bool { !(on && (chosen || fits)) }

    /// The tools the inspector lists, and how many more there are.
    static let shownTools = 10

    static func tools(allowed: [String], granted: [String]) -> (shown: [String], more: Int) {
        let all = allowed + granted.map { "\($0) (granted)" }
        return (Array(all.prefix(shownTools)), max(0, all.count - shownTools))
    }

    /// The one line under a step's switch. Verifier and Judge are Workbench's own and have one; a review stage comes from the project's
    /// config and says nothing of its own.
    static func description(forStep name: String) -> String? {
        switch name {
        case "verifier": "Drives the app from the request and posts screenshots."
        case "judge": "Checks the work against your criteria. Needs at least one."
        default: nil
        }
    }

    /// The foot: where the goal is saved, as the goal model names it.
    static func savedTo(_ goal: GoalModel) -> String { "Saved to \(goal.path)" }

    static let draftNote = "Settings change while the goal is a draft."
    static let ranNote = "A goal that has run is not edited."
    static let readOnlyNote = draftNote

    /// Why the settings are read-only, when they are for a reason that lasts; nil while editable, and nil while only an action is going.
    static func note(goal: GoalModel, lastTurn: Int) -> String? {
        if lastTurn > 0 { return ranNote }
        return goal.editable ? nil : draftNote
    }
}

/// What this thread's run is allowed to do, in one column: the steps after a turn, the limits, the tools, the folders it may read, and
/// the ways to open the thread elsewhere. It shows what the Goal screen shows and writes through the same edits and actions.
struct RunSettingsInspector: View {
    var snapshot: ThreadSnapshot
    var goal: GoalModel?
    var store: ProjectStore
    /// The sheet has the title already.
    var showsTitle = true
    /// What an action said, inside the column: in the sheet the feed with its message rows is behind it, out of sight.
    var showsMessages = false
    @State private var addingFolder = false
    @State private var folderText = ""
    @Environment(\.feedDrawsEagerly) private var drawsEagerly

    var body: some View {
        if drawsEagerly { content } else { ScrollView { content } }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsTitle { heading }
            if let goal {
                if let note = RunSettingsLayout.note(goal: goal, lastTurn: snapshot.state.lastTurn) {
                    Text(note).font(.callout).foregroundStyle(.secondary)
                }
                let editable = store.goalEditable(snapshot, goal: goal)
                afterTheTurn(goal, editable: editable)
                limits(goal)
                tools(goal)
                folders(goal, editable: editable)
                openers(goal)
                Text(RunSettingsLayout.savedTo(goal)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.fg3)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if let error = store.goalEditError { Text(error).font(.callout).foregroundStyle(Theme.red) }
                if showsMessages {
                    MessageRows(
                        error: store.actionError, note: store.actionNote, notice: store.notice,
                        handoff: store.herdrHandoffOutcome)
                }
            } else {
                Text("There is no goal to show settings for.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The artboard's heading: the name and an X that closes the panel (the header's button does the same).
    private var heading: some View {
        HStack {
            Text("Run settings").font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 8)
            Button { store.setRunSettings(false) } label: { Image(systemName: "xmark").font(.system(size: 11)) }
                .buttonStyle(.borderless).help("Close Run settings").accessibilityLabel("Close Run settings")
        }
    }

    private func mono(_ text: String) -> some View {
        Text(text).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: After the turn

    private func afterTheTurn(_ goal: GoalModel, editable: Bool) -> some View {
        section("AFTER THE TURN") {
            ForEach(goal.steps, id: \.name) { step in
                let on = !step.skipped && step.unavailable == nil
                // The switch at the left, the label and what it does beside it, as the artboard has them.
                HStack(alignment: .top, spacing: 10) {
                    Toggle(
                        step.label,
                        isOn: Binding(
                            get: { on }, set: { _ in Task { await store.editGoal { $0.togglingSkip(step.name) } } })
                    )
                    .toggleStyle(.switch).labelsHidden().switchTint().controlSize(.small)
                    .disabled(!editable || step.unavailable != nil)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.label).font(.system(size: 13, weight: .medium))
                        if let line = RunSettingsLayout.description(forStep: step.name) {
                            Text(line).font(.system(size: 11.5)).foregroundStyle(Theme.fg3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .help(
                    step.unavailable.map { "Not available: \($0)" }
                        ?? (step.known ? (on ? "Runs after a turn" : "Skipped for this goal") : "Not a step of this project"))
            }
            adviceSwitch(goal.advice, editable: editable)
            ForEach(goal.steps.filter { $0.unavailable != nil }, id: \.name) { step in
                Text("\(step.label) not available: \(step.unavailable ?? "")")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One switch for the advice: the steps themselves are the switches above, this says whether they run by themselves after a turn.
    private func adviceSwitch(_ advice: AutoAdviceSetting, editable: Bool) -> some View {
        // The switch at the left and everything it says beside it, one column, as the steps above.
        HStack(alignment: .top, spacing: 10) {
            Toggle(
                AutoAdviceSetting.label,
                isOn: Binding(get: { advice.on }, set: { _ in Task { await store.toggleAdvice() } })
            )
            .toggleStyle(.switch).labelsHidden().switchTint().controlSize(.small)
            .disabled(!advice.switchEnabled(editable: editable))
            VStack(alignment: .leading, spacing: 2) {
                Text(AutoAdviceSetting.label).font(.system(size: 13, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(advice.line).font(.system(size: 11.5)).foregroundStyle(Theme.fg3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(advice.source).font(.system(size: 11.5)).foregroundStyle(Theme.fg3)
            }
        }
        .padding(.top, 10)
        .help("Runs the judge and the review stages after a turn that passed, unasked. Each costs what its agent costs.")
    }

    // MARK: Limits and tools

    private func limits(_ goal: GoalModel) -> some View {
        section("LIMITS") {
            // Labels and values in two columns, so the values start where each other do.
            Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 6) {
                limit("Model", goal.model)
                limit("Budget", goal.budget)
                limit("Timeout", goal.turnTimeout)
            }
            Text("Change these in the goal file.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func limit(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(Theme.fg2)
            Text(value).font(.system(.callout, design: .monospaced)).fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.trailing).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.callout)
    }

    @ViewBuilder private func tools(_ goal: GoalModel) -> some View {
        let tools = RunSettingsLayout.tools(allowed: goal.allowedTools, granted: goal.grantedTools)
        if !tools.shown.isEmpty {
            section("ALLOWED TOOLS · \(goal.allowedTools.count + goal.grantedTools.count)") {
                FlowLayout(spacing: 5) {
                    ForEach(tools.shown, id: \.self) { Chip(text: $0, mono: true) }
                    if tools.more > 0 { Chip(text: "+\(tools.more) more", mono: false) }
                }
            }
        }
    }

    // MARK: Reference folders

    @ViewBuilder private func folders(_ goal: GoalModel, editable: Bool) -> some View {
        if !goal.readAlso.isEmpty || !goal.goalReadAlso.isEmpty || editable {
            section("REFERENCE FOLDERS") {
                Text("Read-only for the run").font(.caption).foregroundStyle(.secondary)
                ForEach(goal.readAlso, id: \.self) { folder in
                    folderLine(folder, note: "from project config", removable: false)
                }
                ForEach(goal.goalReadAlso, id: \.self) { folder in
                    folderLine(folder, note: "this goal", removable: editable)
                }
                if editable { addFolder }
            }
        }
    }

    private func folderLine(_ folder: String, note: String, removable: Bool) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                mono(folder)
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if removable {
                Button {
                    Task { await store.editGoal { $0.removingReadAlso(folder) } }
                } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Remove \(folder)")
            }
        }
    }

    @ViewBuilder private var addFolder: some View {
        if addingFolder {
            HStack(spacing: 6) {
                TextField("../backend", text: $folderText).textFieldStyle(.roundedBorder).font(.callout)
                    .onSubmit(commitFolder)
                Button("Add", action: commitFolder).plainButton()
                    .disabled(folderText.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { (addingFolder, folderText) = (false, "") }.plainButton()
            }
            Text("A git checkout: ../backend, ~/shared or an absolute path").font(.caption).foregroundStyle(.secondary)
        } else {
            Button("+ reference folder") { addingFolder = true }.plainButton(fill: true)
        }
    }

    private func commitFolder() {
        let text = folderText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        (addingFolder, folderText) = (false, "")
        Task { await store.editGoal { $0.addingReadAlso(text) } }
    }

    // MARK: Open

    private func openers(_ goal: GoalModel) -> some View {
        section("OPEN") {
            // Once a thread has run, the step's "…" menu has Open worktree and Open in Herdr: only the goal file is left to list here.
            let ran = RunSettingsLayout.hasWorktree(snapshot.state)
            Button(ran ? "Open goal file" : "Open in editor") { Task { await store.openGoalFile() } }
                .help("Opens the goal file in your editor")
            if store.herdrFound, !ran {
                Button("Open in Herdr") { Task { await store.openInHerdr() } }
                    .disabled(store.busy != nil)
                    .help("Herdr opens this thread's worktree, or the project when it has none, without starting anything")
            }
            if store.canRunGoalInHerdr(snapshot, goal: goal) {
                Button(goal.pill == .approved ? "Run in Herdr instead" : "Approve and run in Herdr instead") {
                    Task { await store.runGoalInHerdr() }
                }
                .disabled(store.goalRunDisabled(snapshot, goal: goal))
                .help("Approves the goal, cuts the worktree and starts a Claude session on it in Herdr")
            }
        }
        .plainButton(fill: true)
    }
}

/// The inspector over the feed, for a window too narrow to have it beside.
struct RunSettingsSheet: View {
    var snapshot: ThreadSnapshot
    var store: ProjectStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Run settings").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).plainButton()
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            RunSettingsInspector(snapshot: snapshot, goal: store.goal, store: store, showsTitle: false, showsMessages: true)
        }
        .frame(width: 420, height: 560).background(Theme.rail)
    }
}
