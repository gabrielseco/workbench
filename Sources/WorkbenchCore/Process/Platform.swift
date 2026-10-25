import Foundation
#if !canImport(Darwin)
import Glibc
#endif

// The one place that picks the operating system's implementation of the contract.
#if canImport(Darwin)
typealias CurrentPlatform = DarwinPlatform
#else
typealias CurrentPlatform = LinuxPlatform
#endif

typealias PlatformServices = ProcessInspecting & SpawnPlatform & ExitNotifying & Subreaping & Sendable

/// What the code calls. Not a global of the concrete type, so a test can run the contract on any conforming value.
let platform: some PlatformServices = CurrentPlatform()

// Where macOS and Linux differ in the system calls and structs the rest of the code uses, so it has no `#if`. The free
// functions also keep a type's own `open`/`close`/`read` from shadowing the libc one.

public func sysOpen(_ path: String, _ flags: Int32, _ mode: mode_t = 0) -> Int32 { open(path, flags, mode) }
func sysClose(_ fd: Int32) { _ = close(fd) }
func sysRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int { read(fd, buffer, count) }
func sysRename(_ from: String, _ to: String) -> Int32 { rename(from, to) }

extension stat {
    var modifiedTime: timespec {
        #if canImport(Darwin)
        st_mtimespec
        #else
        st_mtim
        #endif
    }

    var changedTime: timespec {
        #if canImport(Darwin)
        st_ctimespec
        #else
        st_ctim
        #endif
    }
}

extension siginfo_t {
    /// The child a `waitid` reported on (0 when `WNOHANG` found none).
    var childPID: pid_t {
        #if canImport(Darwin)
        si_pid
        #else
        _sifields._sigchld.si_pid
        #endif
    }
}
