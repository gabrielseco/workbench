import Testing

@testable import WorkbenchCore

@Suite struct ThreadStatePullRequestTests {
    @Test func noPullRequestBeforeShip() {
        var story = SpineStory()
        story.approve()
        story.turn(1)
        #expect(story.state.pullRequest == nil && !story.state.cleaned)
    }

    @Test func pullRequestComesFromPROpened() throws {
        var story = SpineStory()
        story.turn(1)
        story.ship(number: 482, head: "deadbeef")
        let pr = try #require(story.state.pullRequest)
        #expect(pr.number == 482 && pr.headSHA == "deadbeef" && pr.url.hasSuffix("/482") && pr.seq == story.events.count)
    }

    @Test func theLatestPROpenedWins() {
        var story = SpineStory()
        story.ship(number: 1)
        story.ship(number: 2)
        #expect(story.state.pullRequest?.number == 2)
    }

    @Test func aPROpenedWithoutANumberOrURLIsIgnored() {
        var story = SpineStory()
        story.add(.prOpened, ["url": "https://example.test/pull/1"])
        story.add(.prOpened, ["number": 3])
        #expect(story.state.pullRequest == nil)
    }

    @Test func theLastEndedTurnRecordsItsSeq() {
        var story = SpineStory()
        story.turn(1)
        #expect(story.state.lastTurnEndedSeq == 2)
    }

    @Test func aMergeCountsOnlyForThePullRequestTheLogNames() {
        var story = SpineStory()
        story.approve()
        story.turn(1)
        story.decide("accepted")
        story.ship(number: 482)
        #expect(!story.state.isMerged)
        story.add(.prMerged, ["number": 482, "head_sha": "deadbeef"])
        #expect(story.state.isMerged)
        // The log says merged, so the spine and attention agree without any read of GitHub.
        let spine = ThreadSpine.derive(state: story.state)
        #expect(Attention.derive(spine: spine, state: story.state) == .none)
        // A later pull request is not the merged one.
        story.ship(number: 483)
        #expect(!story.state.isMerged)
    }

    @Test func aCloseCountsOnlyForThePullRequestTheLogNamesAndAMergeOutranksIt() {
        var story = SpineStory()
        story.approve()
        story.turn(1)
        story.decide("accepted")
        story.ship(number: 482)
        story.add(.prClosed, ["number": 482, "head_sha": "deadbeef"])
        #expect(story.state.isClosed && story.state.settledOutcome() == .closed)
        // The log says closed, so the spine and attention agree without any read of GitHub.
        let spine = ThreadSpine.derive(state: story.state)
        #expect(Attention.derive(spine: spine, state: story.state) == .none)
        // A read that says merged outranks the recorded close, and a recorded merge outranks both.
        #expect(story.state.settledOutcome(.merged) == .merged)
        story.add(.prMerged, ["number": 482, "head_sha": "deadbeef"])
        #expect(story.state.settledOutcome(.closed) == .merged)
        // A later pull request is not the closed one.
        story.ship(number: 483)
        #expect(!story.state.isClosed && story.state.settledOutcome() == .open)
    }
}
