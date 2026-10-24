// A standalone case for the Swift 6.2.1 optimizer bug that Workbench works around (see Package.swift). Compile it with
//   swiftc -O -parse-as-library -Xfrontend -sil-verify-all simplify-cfg-async.swift
// A toolchain with the bug aborts: "SIL verification failed: branch argument types do not match arguments for dest bb", while running
// pass "JumpThreadSimplifyCFG" on `Recorder.record(_:activity:)`. With `-Xllvm -sil-disable-pass=simplify-cfg` it compiles.
// `scripts/swift-bug-repro.sh` runs both and says whether the installed toolchain still has it.
import Foundation

enum RawLine { case line(String), oversized(preview: String, totalBytes: Int), late(String) }
enum Activity { case text(String), diagnostic(String) }

actor Log {
    var count = 0
    func append(_ n: Int) throws { count += n }
}

final class Recorder: @unchecked Sendable {
    let log = Log()
    var sawOutput = false
    var written = 0
    var overCap = 0
    var lastMark = Date()
    let now: @Sendable () -> Date = { Date() }

    func data(_ a: Activity) -> Int? {
        switch a {
        case .text(let t): t.isEmpty ? nil : t.count
        case .diagnostic(let t): t.count
        }
    }

    func flush() async throws {
        guard overCap > 0 else { return }
        try await log.append(overCap)
        overCap = 0
        lastMark = now()
    }

    func record(_ line: RawLine, activity: [Activity]) async throws {
        var items = activity
        switch line {
        case .line, .late: break
        case .oversized(_, let total):
            if items.isEmpty { items = [.diagnostic("a line of \(total) bytes was over the size limit and cut")] }
        }
        if case .late = line {} else { sawOutput = true }
        for item in items {
            guard let d = data(item) else { continue }
            if written >= 1000 {
                overCap += 1
                if now().timeIntervalSince(lastMark) >= 30 { try await flush() }
            } else {
                written += 1
                if written == 1000 { lastMark = now() }
                try await log.append(d)
            }
        }
    }
}

@main struct M {
    static func main() async throws {
        let r = Recorder()
        try await r.record(.line("x"), activity: [.text("hello"), .text("")])
        try await r.record(.oversized(preview: "p", totalBytes: 9), activity: [])
        print(await r.log.count, r.written)
    }
}
