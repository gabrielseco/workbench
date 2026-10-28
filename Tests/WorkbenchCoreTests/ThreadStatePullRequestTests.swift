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
}
