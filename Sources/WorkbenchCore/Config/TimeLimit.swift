import Foundation

extension TimeInterval {
    /// Config keys that end in `_min` hold whole minutes; the runner and the process layer count seconds. Convert only here.
    public static func minutes(_ count: Int) -> TimeInterval { TimeInterval(count) * 60 }
}

extension Goal {
    /// `turn_timeout_min` in seconds.
    public var turnTimeout: TimeInterval { .minutes(turnTimeoutMin) }
}

extension VerifierConfig {
    /// `timeout_min` in seconds.
    public var timeout: TimeInterval { .minutes(timeoutMin) }
}
