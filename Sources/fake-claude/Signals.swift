import Foundation

/// Process id of the grandchild this fake started, 0 when none. Read from the signal handler, so it is a
/// plain global written once before the handler can matter.
nonisolated(unsafe) var grandchildPID: pid_t = 0

/// Mimics the real CLI on SIGTERM (spike S6): stop the tool child it started, then exit 143.
let terminateHandler: @convention(c) (Int32) -> Void = { _ in
    if grandchildPID > 0 { kill(grandchildPID, SIGKILL) }
    _exit(143)
}
