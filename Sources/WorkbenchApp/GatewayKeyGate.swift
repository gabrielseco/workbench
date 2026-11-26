import Foundation
import WorkbenchCore

/// Holds a project back from the window until the gateway key a Dock-started app lacks has been read from the login shell, so nothing
/// can be started without it. The window is not touched while the shell is asked, so nothing can interleave with a half-made switch.
@MainActor final class GatewayKeyGate {
    /// `LoginShellVariable.fillGatewayKey` outside tests. It returns at once for a project that needs no key or has it.
    var fill: (Project) async -> Void = { await LoginShellVariable.fillGatewayKey(project: $0) }
    private var latest = 0

    /// False when the window was asked for something else while this project waited: that wins. `generation` is the store's count
    /// of project switches, which a failed open raises too.
    func ready(_ project: Project, generation: () -> Int) async -> Bool {
        latest += 1
        let (mine, before) = (latest, generation())
        await fill(project)
        return mine == latest && before == generation()
    }
}
