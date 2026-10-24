import Foundation
import Testing

@testable import WorkbenchCore

// MARK: a scripted provider

/// A provider whose "CLI" is a shell script, so the common lifecycle can be tested without a paid agent.
/// Every line it prints is `.text`; it succeeds when the script printed `DONE` and says `at capacity` on stderr
/// when that is what the script did.
private struct ScriptProvider: AgentProvider {
    var id = AgentProviderID("fake")!
    var capabilities = AgentCapabilities(
        policies: [.scopedCoding, .readOnlyEvidence], resume: .returnedID, streamsActivity: true)
    var script: String
    var executable = "/bin/sh"
    var lateLine = false

    func invocation(for request: AgentRequest) throws -> AgentInvocation {
        AgentInvocation(
            executable: executable, arguments: ["-c", script], environment: ["PATH": "/usr/bin:/bin"],
            displayArguments: ["-c", "<script>"])
    }

    func makeDecoder(for request: AgentRequest) -> any AgentDecoder { ScriptDecoder(late: lateLine) }
}

private struct ScriptDecoder: AgentDecoder {
    var sawDone = false
    var last = ""
    /// A dropped line may have been the result, so a decoder that cannot tell fails closed.
    var lostLine = false
    var late = false

    mutating func consume(line: String) -> [AgentActivity] {
        if line == "DONE" { sawDone = true }
        last = line
        return [.text(line)]
    }

    mutating func consume(oversizedPreview preview: String, totalBytes: Int) -> [AgentActivity] {
        lostLine = true
        return []
    }

    mutating func finish(exit: ProcessExit) -> AgentDecoderResult {
        if late { return AgentDecoderResult(outcome: .succeeded, lateLine: "the last line") }
        if lostLine { return AgentDecoderResult(outcome: .unknown) }
        if exit.stderrTail.contains("at capacity") {
            return AgentDecoderResult(
                outcome: .failed, failure: AgentFailure(.capacity, "The provider is at capacity.", retry: .transient))
        }
        return AgentDecoderResult(outcome: sawDone ? .succeeded : .unknown, answer: sawDone ? .text(last) : nil)
    }
}

private func request(
    _ provider: AgentProviderID = AgentProviderID("fake")!, timeout: TimeInterval = 60, buffered: Int = 1024,
    tweak: (inout AgentRequest) -> Void = { _ in }
) -> AgentRequest {
    var r = AgentRequest(
        provider: provider, prompt: "do it", workingDirectory: URL(fileURLWithPath: "/tmp"),
        outputDirectory: URL(fileURLWithPath: "/tmp"), policy: .readOnlyEvidence, spend: .timeoutOnly,
        purpose: .judge, environment: [:], limits: AgentLimits(timeout: timeout, maxBufferedActivity: buffered))
    tweak(&r)
    return r
}

private func finish(_ script: String, _ request: AgentRequest = request()) async throws -> (AgentCompletion, [AgentActivity]) {
    let execution = try AgentRunner.start(provider: ScriptProvider(script: script), request: request)
    var seen: [AgentActivity] = []
    for await item in execution.activity { seen.append(item) }
    return (await execution.completion, seen)
}

// MARK: lifecycle

@Suite(.processGate) struct AgentRunnerTests {
    @Test func activityComesInOrderThenOneCompletionThatSucceeded() async throws {
        let (completion, seen) = try await finish("echo one; echo two; echo DONE")
        let texts = seen.compactMap { if case .text(let t) = $0 { t } else { nil } }
        #expect(texts == ["one", "two", "DONE"])
        if case .started? = seen.first {} else { Issue.record("the first activity is the start: \(seen)") }
        #expect(completion.succeeded)
        #expect(completion.answer == .text("DONE"))
        #expect(completion.failure == nil)
    }

    @Test func exitZeroWithNothingUsableIsNotSuccess() async throws {
        let (completion, _) = try await finish("echo hello")
        #expect(completion.process.termination == .exited(0))
        #expect(completion.provider == .unknown)
        #expect(!completion.succeeded, "a clean exit is not a result")
    }

    @Test func aNonzeroExitIsAProcessFailureWithTheEndOfStderr() async throws {
        let (completion, _) = try await finish("echo DONE; echo boom >&2; exit 3")
        #expect(!completion.succeeded)
        #expect(completion.failure?.kind == .process)
        #expect(completion.failure?.message.contains("status 3") == true)
        #expect(completion.failure?.message.contains("boom") == true)
    }

    @Test func theProvidersOwnExplanationWinsOverTheExitStatus() async throws {
        let (completion, _) = try await finish("echo 'at capacity' >&2; exit 1")
        #expect(completion.failure?.kind == .capacity)
        #expect(completion.failure?.retry == .transient)
    }

    @Test func aMissingExecutableFailsBeforeAnyProcess() throws {
        var provider = ScriptProvider(script: "true")
        provider.executable = "workbench-no-such-agent"
        let failure = #expect(throws: AgentFailure.self) { try AgentRunner.start(provider: provider, request: request()) }
        #expect(failure?.kind == .missingExecutable)
        #expect(failure?.retry == .afterFix)
    }

    @Test func stoppingEndsTheChildAndIsRecordedAsCancellation() async throws {
        let execution = try AgentRunner.start(provider: ScriptProvider(script: "echo started; sleep 300"), request: request())
        var iterator = execution.activity.makeAsyncIterator()
        while let item = await iterator.next() {
            if case .text("started") = item { break }
        }
        execution.stop()
        execution.stop()
        let completion = await execution.completion
        #expect(completion.process.cause == .stopped)
        #expect(completion.failure?.kind == .cancellation)
        #expect(!completion.succeeded)
        #expect(await execution.completion == completion, "awaiting again gives the same completion")
    }

    @Test func theDeadlineEndsTheChildAsATimeout() async throws {
        let (completion, _) = try await finish("sleep 300", request(timeout: 1))
        #expect(completion.process.cause == .timedOut)
        #expect(completion.failure?.kind == .timeout)
    }

    @Test func aConsumerThatNeverReadsCannotHoldTheChildOpen() async throws {
        let execution = try AgentRunner.start(
            provider: ScriptProvider(script: "i=0; while [ $i -lt 5000 ]; do echo line$i; i=$((i+1)); done; echo DONE"),
            request: request(buffered: 8))
        let completion = await execution.completion
        #expect(completion.succeeded, "the child finished with nobody reading its activity")
        #expect(completion.droppedActivity > 0)
    }

    @Test func aLineOverTheLimitIsReportedToTheDecoderAndCanFailTheAnswer() async throws {
        let (completion, seen) = try await finish(
            "echo DONE; head -c 5000 /dev/zero | tr '\\0' x; echo",
            request { $0.limits.maxLineBytes = 1024 })
        #expect(seen.contains { if case .diagnostic = $0 { true } else { false } })
        #expect(completion.oversizedLines == 1)
        #expect(!completion.succeeded, "a usable answer followed by a lost record is not a result")
        #expect(completion.provider == .unknown)
    }

    @Test func aStopOrADeadlineBeatsWhatTheProviderSaidBeforeIt() async throws {
        let script = "echo 'at capacity' >&2; sleep 300"
        let timed = try await finish(script, request(timeout: 1)).0
        #expect(timed.failure?.kind == .timeout)
        #expect(timed.failure?.retry == .never, "a deadline is not a capacity retry")
        #expect(timed.failure?.diagnostic?.contains("capacity") == true, "the provider's message is kept")

        let execution = try AgentRunner.start(provider: ScriptProvider(script: script), request: request())
        var iterator = execution.activity.makeAsyncIterator()
        _ = await iterator.next()  // started
        execution.stop()
        let stopped = await execution.completion
        #expect(stopped.failure?.kind == .cancellation)
        #expect(stopped.failure?.retry == .never)
    }

    @Test func negativeLimitsAreRefusedNotTrapped() throws {
        let provider = ScriptProvider(script: "echo boom >&2; exit 1")
        for tweak: (inout AgentLimits) -> Void in [
            { $0.maxRawBytes = -1 }, { $0.timeout = 0 }, { $0.maxLineBytes = 0 }, { $0.maxOutputBytes = -5 },
            { $0.maxBufferedActivity = 0 },
        ] {
            let bad = request { tweak(&$0.limits) }
            let failure = #expect(throws: AgentFailure.self) { try AgentRunner.start(provider: provider, request: bad) }
            #expect(failure?.kind == .unsupportedCapability)
        }
    }
}

// MARK: the recorder

private final class Collector: AgentRecorder, @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [AgentRawLine] = []
    var failAfter: Int?
    func record(_ line: AgentRawLine, activity: [AgentActivity]) async throws {
        let count = lock.withLock { () -> Int in lines.append(line); return lines.count }
        if let failAfter, count >= failAfter { throw RecorderError.refused }
    }
    var recorded: [AgentRawLine] { lock.withLock { lines } }
    enum RecorderError: Error { case refused }
}

@Suite(.processGate) struct AgentRecorderTests {
    @Test func everyLineIsRecordedInOrderEvenWhenTheActivityStreamDropsMost() async throws {
        let collector = Collector()
        let script = "i=0; while [ $i -lt 3000 ]; do echo line$i; i=$((i+1)); done; echo DONE"
        let execution = try AgentRunner.start(
            provider: ScriptProvider(script: script), request: request(buffered: 4), recorder: collector)
        let completion = await execution.completion
        #expect(completion.droppedActivity > 0, "the bounded stream lost activity")
        let lines = collector.recorded.compactMap { if case .line(let l) = $0 { l } else { nil } }
        #expect(lines.count == 3001 && lines.first == "line0" && lines.last == "DONE", "the recorder lost nothing")
        #expect(lines == (0..<3000).map { "line\($0)" } + ["DONE"])
    }

    @Test func aHeldExecutionRecordsNothingUntilItIsBegun() async throws {
        let collector = Collector()
        let execution = try AgentRunner.start(
            provider: ScriptProvider(script: "echo one; echo DONE"), request: request(), recorder: collector, held: true)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(collector.recorded.isEmpty, "the caller writes what must come first, then begins")
        execution.begin()
        execution.begin()
        let completion = await execution.completion
        #expect(completion.succeeded)
        #expect(collector.recorded.count == 2)
    }

    @Test func aHeldExecutionThatIsStoppedStillEnds() async throws {
        let execution = try AgentRunner.start(
            provider: ScriptProvider(script: "sleep 300"), request: request(), recorder: Collector(), held: true)
        execution.stop()
        let completion = await execution.completion
        #expect(completion.failure?.kind == .cancellation)
    }

    @Test func aRecorderThatThrowsStopsTheChildAndTheRestIsNotRecorded() async throws {
        let collector = Collector()
        collector.failAfter = 2
        let execution = try AgentRunner.start(
            provider: ScriptProvider(script: "echo a; echo b; echo c; sleep 300"), request: request(), recorder: collector)
        let completion = await execution.completion
        #expect(completion.recordingFailure?.contains("refused") == true)
        #expect(completion.process.cause == .stopped, "the child did not run on")
        #expect(collector.recorded.count == 2)
    }

    @Test func aLateLineIsRecordedAfterTheStream() async throws {
        let collector = Collector()
        var provider = ScriptProvider(script: "echo one; echo two")
        provider.lateLine = true
        let execution = try AgentRunner.start(provider: provider, request: request(), recorder: collector)
        _ = await execution.completion
        #expect(collector.recorded.last == .late("the last line"))
    }
}

// MARK: refusals before anything is spawned

@Suite struct AgentRequestValidationTests {
    private let provider = ScriptProvider(script: "true")

    private func refusal(_ tweak: (inout AgentRequest) -> Void) -> AgentFailure? {
        request(tweak: tweak).validate(against: provider)
    }

    @Test func aValidRequestPasses() {
        #expect(refusal { _ in } == nil)
    }

    @Test func aDollarCapNeedsAProviderThatEnforcesIt() {
        let failure = refusal { $0.spend = .hardCap(5) }
        #expect(failure?.kind == .unsupportedCapability)
        #expect(failure?.message.contains("timeout-only") == true, "says what to do instead")
        var capped = provider
        capped.capabilities.hardDollarCap = true
        #expect(request { $0.spend = .hardCap(5) }.validate(against: capped) == nil)
    }

    @Test func aPolicyTheProviderHasNoControlsForIsRefusedNotWeakened() {
        var readOnly = provider
        readOnly.capabilities.policies = [.readOnlyEvidence]
        #expect(request { $0.policy = .scopedCoding }.validate(against: readOnly)?.kind == .unsupportedCapability)
    }

    @Test func imagesNeedImageSupport() {
        #expect(refusal { $0.images = [URL(fileURLWithPath: "/tmp/a.png")] }?.kind == .unsupportedCapability)
    }

    @Test func aRequestForAnotherProviderIsRefused() {
        #expect(refusal { $0.provider = .claude }?.kind == .unsupportedCapability)
    }

    @Test func aSessionOfAnotherProviderOrPurposeIsNeverResumed() {
        let other = AgentSessionHandle(provider: .claude, purpose: .judge, value: "abc")
        #expect(refusal { $0.session = .resume(other) } != nil, "a Claude handle on the fake provider")
        let coder = AgentSessionHandle(provider: AgentProviderID("fake")!, purpose: .coding, value: "abc")
        #expect(refusal { $0.session = .resume(coder) } != nil, "a coding session is not a judge's")
        let mine = AgentSessionHandle(provider: AgentProviderID("fake")!, purpose: .judge, value: "abc")
        #expect(refusal { $0.session = .resume(mine) } == nil)
    }

    @Test func aProviderWithoutResumeKeepsNoConversation() {
        var none = provider
        none.capabilities.resume = .none
        #expect(request { $0.session = .start(proposed: nil) }.validate(against: none) != nil)
        #expect(request().validate(against: none) == nil, "one-shot is always fine")
    }

    @Test func badModelNamesAndEmptyPromptsAreRefused() {
        #expect(refusal { $0.model = "--dangerously-skip" } != nil)
        #expect(refusal { $0.prompt = "  \n" } != nil)
        #expect(refusal { $0.model = "opus" } == nil)
    }

    @Test func providerIDsAreCheckedNames() {
        #expect(AgentProviderID("codex") != nil)
        #expect(AgentProviderID("Codex") == nil)
        #expect(AgentProviderID("../x") == nil)
        #expect(AgentProviderID("") == nil)
    }
}
