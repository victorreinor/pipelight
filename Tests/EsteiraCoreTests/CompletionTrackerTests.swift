import Foundation
import Testing
@testable import EsteiraCore

@Suite struct AnnouncingFinishedRuns {
    @Test func firstLookAnnouncesNothing() {
        var tracker = CompletionTracker()
        #expect(tracker.completions(in: [run(2, "completed", "failure"), run(1)], target: "t").isEmpty)
    }

    @Test func runThatWasGoingIsAnnouncedWhenItEnds() {
        var tracker = CompletionTracker()
        _ = tracker.completions(in: [run(2, "in_progress"), run(1)], target: "t")
        let found = tracker.completions(in: [run(2), run(1)], target: "t")
        #expect(found.map(\.run.id) == [2])
        #expect(found.first?.previous?.id == 1)
    }

    @Test func runThatStartedAndEndedBetweenLooksIsAnnounced() {
        var tracker = CompletionTracker()
        _ = tracker.completions(in: [run(1)], target: "t")
        #expect(tracker.completions(in: [run(2, "completed", "failure"), run(1)], target: "t").map(\.run.id) == [2])
    }

    @Test func eachResultIsAnnouncedOnce() {
        var tracker = CompletionTracker()
        _ = tracker.completions(in: [run(2, "in_progress"), run(1)], target: "t")
        _ = tracker.completions(in: [run(2), run(1)], target: "t")
        #expect(tracker.completions(in: [run(2), run(1)], target: "t").isEmpty)
    }

    @Test func reRunIsAnnouncedAgain() {
        var tracker = CompletionTracker()
        _ = tracker.completions(in: [run(2, "completed", "failure")], target: "t")
        _ = tracker.completions(in: [run(2, "in_progress", attempt: 2)], target: "t")
        let found = tracker.completions(in: [run(2, attempt: 2)], target: "t")
        #expect(found.map(\.run.key) == [RunKey(id: 2, attempt: 2)])
    }

    @Test func previousIsTheSameWorkflowAndIgnoresCancelled() {
        var tracker = CompletionTracker()
        _ = tracker.completions(in: [], target: "t")
        let found = tracker.completions(in: [
            run(4), run(3, workflow: "CodeQL"), run(2, "completed", "cancelled"), run(1, "completed", "failure"),
        ], target: "t")
        #expect(found.first { $0.run.id == 4 }?.previous?.id == 1)
    }

    @Test func branchesAreIndependent() {
        var tracker = CompletionTracker()
        _ = tracker.completions(in: [run(1)], target: "a")
        #expect(tracker.completions(in: [run(2)], target: "b").isEmpty)
        #expect(tracker.completions(in: [run(3), run(1)], target: "a").map(\.run.id) == [3])
    }

    @Test func forgottenBranchStartsOverQuietly() {
        var tracker = CompletionTracker()
        _ = tracker.completions(in: [run(1)], target: "t")
        tracker.forget(target: "t")
        #expect(tracker.completions(in: [run(2), run(1)], target: "t").isEmpty)
    }
}

@Suite struct NotificationText {
    @Test func passed() throws {
        let notice = try #require(Notice(repo: "api", branch: "master", completion: Completion(run: run(2), previous: run(1))))
        #expect(notice.kind == .passed)
        #expect(notice.title == "✅ api · master passou")
        #expect(notice.subtitle == "CI · 6 min")
        #expect(notice.body == "commit 2")
        #expect(notice.identifier == "2-1")
    }

    @Test func fixed() {
        let notice = Notice(repo: "api", branch: "homolog", completion: Completion(run: run(2), previous: run(1, "completed", "failure")))
        #expect(notice?.kind == .fixed)
        #expect(notice?.title == "✅ api · homolog voltou a passar")
    }

    @Test func failed() {
        let notice = Notice(repo: "api", branch: "master", completion: Completion(run: run(2, "completed", "failure"), previous: nil))
        #expect(notice?.kind == .failed)
        #expect(notice?.title == "❌ api · master quebrou")
    }

    @Test func cancelledAndSkippedStayQuiet() {
        #expect(Notice(repo: "api", branch: "master", completion: Completion(run: run(2, "completed", "cancelled"))) == nil)
        #expect(Notice(repo: "api", branch: "master", completion: Completion(run: run(2, "completed", "skipped"))) == nil)
    }
}
