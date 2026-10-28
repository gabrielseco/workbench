import Testing

@testable import WorkbenchCore

@Suite struct ThreadStatePullRequestTests {
    @Test func pullRequestIsNilBeforeShip() {
        #expect(SpineStory.accepted().state.pullRequest == nil)
        #expect(ThreadState.derive(from: [], id: "t").pullRequest == nil)
    }

    @Test func pullRequestReadsPROpened() {
        let story = SpineStory.shipped()
        #expect(
            story.state.pullRequest
                == PullRequest(number: 482, url: "https://github.com/o/r/pull/482", headSHA: "feed0001", seq: story.lastSeq))
    }

    @Test func pullRequestLatestWins() {
        var story = SpineStory.shipped()
        story.add(.prOpened, ["url": "https://github.com/o/r/pull/483", "number": 483, "head_sha": "feed0002"])
        #expect(story.state.pullRequest?.number == 483 && story.state.pullRequest?.headSHA == "feed0002")
        story.add(.prOpened, ["url": "no number"])
        #expect(story.state.pullRequest?.number == 483, "a record without a number is not a pull request")
    }
}
