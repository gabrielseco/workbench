/// True when the tests run on Linux. For the few tests that wait for P18 task 4 (the orphan rule): there an orphan is
/// adopted by the nearest subreaper, not always PID 1, which `OrphanSweeper` still assumes.
let onLinux: Bool = {
    #if os(Linux)
    true
    #else
    false
    #endif
}()
