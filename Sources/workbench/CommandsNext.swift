import Foundation
import WorkbenchCore

extension Commands {
    /// `next [id]`: what the thread's log says is still due (judge, the review stages that apply, the decision, `ship`), the first
    /// line being the next step. Read-only and advisory: it runs nothing, and nothing here stops `accept` or `ship`.
    static func next(_ args: [String]) async throws {
        var a = Arguments(args)
        let named = a.positional()
        try a.requireEmpty()
        let ctx = try await Context.load()
        let id = try ctx.threadIDForViewing(named)
        let lines = await nextStepLines(id: id, ctx: ctx)
        if lines.isEmpty { return out("nothing is due: no finished turn to act on, or the thread has ended.") }
        for line in lines { out(line) }
    }

    /// The lines `next` prints; empty when nothing is due. Also what `review` ends with.
    static func nextStepLines(id: String, ctx: Context) async -> [String] {
        guard let events = try? EventLogReader.read(at: ctx.project.eventsURL(id)).events else { return [] }
        let config = try? Config.load(from: ctx.project.configURL)
        let files = await ReviewLoader(project: ctx.project, git: ctx.git).changedFiles(id: id)?.files.map(\.path)
        let steps = NextSteps.derive(events: events, files: files, config: config)
        return NextSteps.render(steps)
    }
}
