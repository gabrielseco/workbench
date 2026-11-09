import Foundation

extension TimerService {
    /// What `refresh` did to one project's timer.
    public struct RefreshResult: Sendable, Equatable {
        public enum Outcome: String, Sendable, Equatable {
            /// Nothing differed: no file was written and the agent was not touched.
            case upToDate
            /// The copy, the launcher or the agent file changed.
            case refreshed
            /// This binary is older than the copy the launcher runs: it is left alone.
            case newerCopyKept
            /// No timer is installed for the project: nothing was written.
            case notInstalled
        }
        public var outcome: Outcome
        public var lines: [String]
    }

    /// Brings an installed timer up to date with this binary, so a pull of main reaches the timers without anyone installing again. It keeps
    /// what the person chose (the interval, `--pull-main`), swaps the copy by rename (a tick that is running keeps the file it started
    /// from) and reloads the agent only when its file changed: unloading an agent ends a tick that is running, and a tick can be a run
    /// that has taken an hour. It never replaces the copy with an older binary, and it never touches the wake schedule.
    public func refresh() async throws -> RefreshResult {
        let fm = FileManager.default
        guard launchctl != nil, fm.fileExists(atPath: paths.plist.path) else {
            let line = "no timer is installed for \(project.root.path): workbench task timer install"
            return RefreshResult(outcome: .notInstalled, lines: [line])
        }
        let current = Self.settings(of: paths)
        func modified(_ url: URL) -> Date? { (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date }
        let source = workbench.resolvingSymlinksInPath()
        let sameFile = source == paths.binary.resolvingSymlinksInPath()
        if !sameFile, let copy = modified(paths.binary), let built = modified(source), copy.timeIntervalSince(built) > 1 {
            return RefreshResult(
                outcome: .newerCopyKept,
                lines: ["the copy the launcher runs is newer than \(workbench.path): left as it is"])
        }
        let launcher = TimerFiles.launcher(
            project: project, workbench: paths.binary, label: paths.label, pullMain: current.pullMain)
        let plist = TimerFiles.plist(paths: paths, project: project, interval: current.interval)
        let copyChanged = !sameFile && !(fm.contentsEqual(atPath: source.path, andPath: paths.binary.path))
        let launcherChanged = (try? String(contentsOf: paths.launcher, encoding: .utf8)) != launcher
        let plistChanged = (try? String(contentsOf: paths.plist, encoding: .utf8)) != plist
        // An agent that is not loaded (a reload that failed half way, or a logout) is loaded here: a retry must not call that "up to date".
        let isLoaded = await agentIsLoaded()
        guard copyChanged || launcherChanged || plistChanged || !isLoaded else {
            return RefreshResult(outcome: .upToDate, lines: ["\(paths.label): up to date"])
        }
        do {
            if copyChanged { try Self.copyBinary(from: workbench, to: paths.binary) }
            if launcherChanged {
                try launcher.write(to: paths.launcher, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.launcher.path)
            }
            if plistChanged { try plist.write(to: paths.plist, atomically: true, encoding: .utf8) }
        } catch { throw TimerError.cannotWrite("\(error)") }
        if plistChanged || !isLoaded, let launchctl {
            if isLoaded { _ = try? await launchctl.run(["bootout", target], in: paths.home) }
            let loaded = try? await launchctl.run(["bootstrap", domain, paths.plist.path], in: paths.home)
            guard let loaded, loaded.succeeded else {
                let why = loaded.map { $0.stderr.trimmingCharacters(in: .whitespacesAndNewlines) } ?? "it could not be run"
                throw TimerError.launchctlFailed("bootstrap", why)
            }
        }
        var what: [String] = []
        if copyChanged { what.append("binary") }
        if launcherChanged { what.append("launcher") }
        if plistChanged || !isLoaded { what.append(isLoaded ? "agent (reloaded)" : "agent (loaded)") }
        return RefreshResult(outcome: .refreshed, lines: ["\(paths.label): refreshed \(what.joined(separator: ", "))"])
    }

    private func agentIsLoaded() async -> Bool {
        guard let launchctl, let printed = try? await launchctl.run(["print", target], in: paths.home) else { return false }
        return printed.succeeded
    }

    /// What the person chose at install, read back from the files: the agent's interval and whether the launcher pulls main.
    static func settings(of paths: TimerPaths) -> (interval: Int, pullMain: Bool) {
        var interval = TimerFiles.defaultInterval
        if let data = try? Data(contentsOf: paths.plist),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let seconds = plist["StartInterval"] as? Int,
            (TimerFiles.minimumInterval...TimerFiles.maximumInterval).contains(seconds) {
            interval = seconds
        }
        let launcher = (try? String(contentsOf: paths.launcher, encoding: .utf8)) ?? ""
        return (interval, launcher.contains("git pull --ff-only"))
    }
}
