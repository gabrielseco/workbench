// The Doctor chip and a row of the recent-projects list: plain values the store holds.
import Foundation

/// What the Doctor chip says. Doctor runs the project's own setup and check in a throwaway worktree, so it costs what
/// the project says and runs only when asked.
enum DoctorChip: Equatable {
    case notRun
    case running
    case healthy(seconds: Double)
    case problem(String)
}

struct RecentProject: Equatable, Identifiable {
    var path: String
    var name: String
    var isCurrent: Bool
    /// This app has a run going in it: switching away does not stop it.
    var isRunning: Bool
    /// Why it cannot be opened now (the folder is gone, it is no longer a git repository); nil when it can.
    var unavailable: String?
    var id: String { path }
}
