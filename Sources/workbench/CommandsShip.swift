import Foundation
import WorkbenchCore

extension Commands {
    /// Exit codes of `ship`: 0 done, 1 any other failure, 2 usage, then one per refusal worth scripting on.
    enum ShipExit {
        static let notAccepted: Int32 = 3
        static let alreadyShipped: Int32 = 4
        static let pushRejected: Int32 = 5
    }

    /// `ship [id] [--yes]`: push the accepted thread's branch and open its pull request. Asks first, because
    /// it publishes; running it again after any failure resumes where it stopped.
    static func ship(_ args: [String]) async throws -> Int32 {
        var a = Arguments(args)
        let yes = a.flag("--yes", "-y")
        let named = a.positional()
        try a.requireEmpty()
        let ctx = try await Context.load()
        let gh = try? GitRunner.discover(tool: "gh")

        let id: String
        do { id = try shippableThread(named, ctx: ctx) } catch let error as ShipError { return refuse(error) }
        if named == nil { out("shipping \(id)") }

        let plan: ShipPlan
        do { plan = try await ctx.service.shipPreflight(id: id, gh: gh) } catch let error as ShipError {
            return refuse(error)
        }
        out("thread:  \(plan.id)")
        out("branch:  \(plan.branch)  (\(plan.head.prefix(12)))")
        out("base:    \(plan.base)")
        out("origin:  \(plan.origin)")
        switch plan.remote {
        case .absent: out("push:    new branch on origin")
        case .upToDate: out("push:    nothing, origin already has this commit")
        case .behind(let sha): out("push:    fast-forward from \(sha.prefix(12))")
        }
        out("then:    open a pull request against \(plan.base)")

        let interactive = isatty(STDIN_FILENO) == 1
        if !yes && interactive { print("Publish this? [y/N] ", terminator: "") }
        switch Confirmation.ask(yes: yes, interactive: interactive, readLine: { readLine() }) {
        case .proceed: break
        case .declined:
            out("nothing changed")
            return 0
        case .refused:
            throw CLIError.message("not shipping: there is no terminal to ask on. Pass --yes to confirm.")
        }

        do {
            let pushed = try await ctx.service.shipPush(id: id, gh: gh, shown: plan)
            out(pushed.outcome == .pushed ? "pushed \(plan.branch)" : "origin already has \(plan.branch)")
            let pr = try await ctx.service.shipOpenPR(id: id, gh: gh, shown: plan)
            out(pr.outcome == .created ? "opened the pull request" : "the pull request already existed; recorded it")
            out(pr.url)
            return 0
        } catch let error as ShipError {
            return refuse(error)
        }
    }

    /// The thread named, or else the most recent one that is accepted and not yet shipped.
    private static func shippableThread(_ named: String?, ctx: Context) throws -> String {
        if let named {
            guard FileManager.default.fileExists(atPath: ctx.project.threadDirectory(named).path) else {
                throw ShipError.notAccepted("there is no thread '\(named)'")
            }
            return named
        }
        let candidates = ctx.store.threadIDs().compactMap { id -> ThreadState? in
            let events = (try? EventLogReader.read(at: ctx.project.eventsURL(id)))?.events ?? []
            let state = ThreadState.derive(from: events, id: id)
            return state.decision == "accepted" && !events.contains { $0.kind == .prOpened } ? state : nil
        }
        guard let latest = candidates.max(by: { ($0.createdAt ?? "") < ($1.createdAt ?? "") }) else {
            throw ShipError.notAccepted("there is no accepted thread waiting to be shipped; `workbench accept` one first")
        }
        return latest.id
    }

    /// Prints why and returns the exit code for it. An already shipped thread also prints its URL, last.
    private static func refuse(_ error: ShipError) -> Int32 {
        switch error {
        case .alreadyShipped(let url):
            err("workbench: \(error)")
            out(url)
            return ShipExit.alreadyShipped
        case .notAccepted:
            err("workbench: \(error)")
            return ShipExit.notAccepted
        case .pushRejected, .remoteDiverged:
            err("workbench: \(error)")
            return ShipExit.pushRejected
        default:
            err("workbench: \(error)")
            return 1
        }
    }
}
