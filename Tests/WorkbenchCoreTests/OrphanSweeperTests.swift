import Foundation
import Testing

@testable import WorkbenchCore

/// A machine described by a table, so the rule for what counts as an orphan is tested without starting anything.
final class Machine: ProcessInspecting, Subreaping, @unchecked Sendable {
    struct Entry {
        var parent: pid_t
        var cwd: String
        var start: UInt64 = 100
    }

    var table: [pid_t: Entry]
    var adopters: Set<pid_t>
    /// A pid whose start changes between two reads: it left and the number was reused.
    var recycled: Set<pid_t> = []
    private var reads: [pid_t: Int] = [:]

    init(_ table: [pid_t: Entry], adopters: Set<pid_t> = [1]) {
        self.table = table
        self.adopters = adopters
    }

    func member(for pid: pid_t) -> ProcessMember? {
        guard let entry = table[pid] else { return nil }
        reads[pid, default: 0] += 1
        let start = recycled.contains(pid) ? entry.start + UInt64(reads[pid]!) : entry.start
        return ProcessMember(pid: pid, startSeconds: start, startMicros: 0)
    }

    func parent(of pid: pid_t) -> pid_t? { table[pid]?.parent }
    func workingDirectory(of pid: pid_t) -> String? { table[pid]?.cwd }
    func allPIDs() -> [pid_t] { Array(table.keys) }
    func children(of pid: pid_t) -> [pid_t] { table.filter { $0.value.parent == pid }.map(\.key) }
    func becomeSubreaper() -> Bool { false }
    var orphanAdopters: Set<pid_t> { adopters }
}

@Suite struct OrphanSweeperTests {
    private let work = URL(fileURLWithPath: "/tmp/wb-orphan-rule-\(UUID().uuidString)/worktree")

    private func found(_ machine: Machine) -> Set<pid_t> {
        Set(OrphanSweeper.orphans(inside: work, on: machine).map(\.pid))
    }

    @Test func aProcessInTheWorktreeWhoseParentIsGoneAndWasAdoptedByInitIsAnOrphan() {
        let machine = Machine([500: .init(parent: 1, cwd: work.path)])
        #expect(found(machine) == [500])
    }

    @Test func underASubreaperTheAdoptedProcessIsFoundToo() {
        // `systemd --user` (pid 900) or a supervisor adopts orphans instead of PID 1.
        let machine = Machine(
            [
                900: .init(parent: 1, cwd: "/"),
                500: .init(parent: 900, cwd: work.path + "/sub"),
            ], adopters: [1, 900])
        #expect(found(machine) == [500])
    }

    @Test func aShellTheUserOpenedInTheWorktreeIsLeftAloneWhateverItsParentsParentIs() {
        // tmux (pid 777) daemonised, so its parent is PID 1: the shell's parent is a live ordinary process, not an adopter.
        // Treating "any process in the worktree outside a live Workbench" as an orphan would kill this shell.
        let machine = Machine(
            [
                777: .init(parent: 1, cwd: "/home/user"),
                778: .init(parent: 777, cwd: work.path),
                779: .init(parent: 778, cwd: work.path),
            ], adopters: [1, 900])
        #expect(found(machine).isEmpty)
    }

    @Test func whatRunsBeneathAnOrphanIsSweptWhereverItHasGoneTo() {
        let machine = Machine(
            [
                500: .init(parent: 1, cwd: work.path),
                501: .init(parent: 500, cwd: "/elsewhere"),
                502: .init(parent: 501, cwd: "/tmp"),
                600: .init(parent: 1, cwd: "/elsewhere"),
            ])
        #expect(found(machine) == [500, 501, 502])
    }

    @Test func anAdoptedProcessOutsideTheWorktreeIsNotTouched() {
        let machine = Machine([500: .init(parent: 1, cwd: "/home/user/project")])
        #expect(found(machine).isEmpty)
        let sibling = Machine([500: .init(parent: 1, cwd: work.path + "-other")])
        #expect(found(sibling).isEmpty, "a folder that only starts with the same name is another folder")
    }

    @Test func aPidReusedWhileTheProcessWasBeingLookedAtIsNotTakenForTheOrphan() {
        let machine = Machine([500: .init(parent: 1, cwd: work.path)])
        machine.recycled = [500]
        #expect(found(machine).isEmpty, "its start changed between the reads, so it is not the process that was checked")
    }

    @Test func thePlatformsOwnAdoptersAreWhatTheRealSweeperUses() {
        #expect(platform.orphanAdopters.contains(1))
    }
}
