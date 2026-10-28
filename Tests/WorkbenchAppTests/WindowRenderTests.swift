import AppKit
import SwiftUI
import Testing
import WorkbenchCore

@testable import WorkbenchApp

/// Draws the window for each state with `ImageRenderer` (no display, no permission, no click): a render that crashes or comes
/// out blank fails, and the PNGs land in `WORKBENCH_RENDER_DIR` (else the temp folder) for the pull request.
@MainActor @Suite struct WindowRenderTests {
    private static var outputDirectory: URL {
        let path = ProcessInfo.processInfo.environment["WORKBENCH_RENDER_DIR"]
        return URL(fileURLWithPath: path ?? NSTemporaryDirectory()).appendingPathComponent("workbench-app-renders")
    }

    /// The number of distinct colours in the image: a blank or one-colour render has one or two.
    private func distinctColours(_ image: CGImage) -> Int {
        let (width, height) = (image.width, image.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard
            let context = CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var seen = Set<UInt32>()
        for index in stride(from: 0, to: pixels.count, by: 4) {
            seen.insert(
                UInt32(pixels[index]) << 16 | UInt32(pixels[index + 1]) << 8 | UInt32(pixels[index + 2]))
            if seen.count > 64 { break }
        }
        return seen.count
    }

    private func render(_ name: String, _ screen: ProjectScreen, doctor: Bool = false) throws {
        let project: Project? = screen == .noProject ? nil : Project(root: URL(fileURLWithPath: "/Users/you/code/remote-flows"))
        let store = ProjectStore(preferences: MemoryPreferences(), screen: screen, project: project)
        let view = RootView(store: store).frame(width: 1100, height: 700)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try #require(renderer.cgImage, "\(name) did not render")
        #expect(image.width == 1100 && image.height == 700, "\(name)")
        #expect(distinctColours(image) > 8, "\(name) came out blank")
        try FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)
        let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        try #require(png).write(to: Self.outputDirectory.appendingPathComponent("\(name).png"))
    }

    private func screen(_ fixture: AppFixture) throws -> ProjectScreen {
        ProjectLoader.load(project: fixture.project).screen
    }

    @Test func aDraftGoal() async throws {
        let fixture = try await AppFixture()
        try await fixture.addThread("draft")
        try render("1-draft", try screen(fixture))
    }

    @Test func aRunningTurn() async throws {
        let fixture = try await AppFixture()
        try await fixture.addThread("run", approved: true)
        try fixture.append("run", .turnStarted, turn: 1, data: ["session_id": "s1"])
        try render("2-running", try screen(fixture))
    }

    @Test func aTurnThatNeedsYou() async throws {
        let fixture = try await AppFixture()
        try await fixture.addThread("review", approved: true)
        try fixture.turn("review", 1, cost: 1.88)
        try render("3-needs-you", try screen(fixture))
    }

    @Test func aPullRequestOpen() async throws {
        let fixture = try await AppFixture()
        try await fixture.addThread("pr", approved: true)
        try fixture.turn("pr", 1)
        try fixture.decide("pr", "accepted")
        try fixture.ship("pr", number: 482)
        try render("4-pr-open", try screen(fixture))
    }

    @Test func mergedAndCleaned() async throws {
        let fixture = try await AppFixture()
        try await fixture.addThread("done", approved: true)
        try fixture.turn("done", 1, cost: nil)
        try fixture.decide("done", "accepted")
        try fixture.ship("done")
        try fixture.append("done", .branchRemoved, data: ["reason": "merged"])
        try render("5-cleaned", try screen(fixture))
    }

    @Test(arguments: [
        ("6-no-project", ProjectScreen.noProject),
        ("7-not-git", ProjectScreen.notAGitRepository(path: "/Users/you/Downloads")),
        ("8-no-workbench", ProjectScreen.workbenchMissing(path: "/Users/you/code/app")),
        ("9-no-thread", ProjectScreen.noThread),
        (
            "10-log-corrupt",
            ProjectScreen.logCorrupt(thread: "ord-3", problems: ["line 7 is not a valid event"])
        ),
    ])
    func eachUnusableProject(name: String, screen: ProjectScreen) throws {
        try render(name, screen)
    }

    @Test func theImageRendererCatchesABlankView() throws {
        let renderer = ImageRenderer(content: Color.white.frame(width: 100, height: 100))
        renderer.scale = 1
        #expect(try distinctColours(#require(renderer.cgImage)) <= 2)
    }
}
