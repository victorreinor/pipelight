import Foundation
import Testing
@testable import PipelightCore

@Suite struct DecodingGhOutput {
    @Test func decodesRunListJSON() throws {
        let json = """
        [{"attempt":2,"conclusion":"","createdAt":"2026-10-28T19:26:28Z","databaseId":40754318913,
          "displayTitle":"fix: busca (#3482)","startedAt":"2026-10-28T19:30:00Z","status":"in_progress",
          "updatedAt":"2026-10-28T19:31:00Z","url":"https://github.com/acme/api/actions/runs/40754318913",
          "workflowName":"Continuous integration"}]
        """
        let runs = try WorkflowRun.decodeList(Data(json.utf8))
        #expect(runs.count == 1)
        #expect(runs[0].id == 40_754_318_913)
        #expect(runs[0].key == RunKey(id: 40_754_318_913, attempt: 2))
        #expect(runs[0].state == .running)
        #expect(runs[0].title == "fix: busca (#3482)")
        #expect(runs[0].startedAt == ISO8601DateFormatter().date(from: "2026-10-28T19:30:00Z"))
    }

    @Test func emptyListIsFine() throws {
        #expect(try WorkflowRun.decodeList(Data("[]".utf8)).isEmpty)
    }

    @Test func mapsStatusesAndConclusions() {
        #expect(run(1, "queued").state == .queued)
        #expect(run(1, "in_progress").state == .running)
        #expect(run(1, "waiting").state == .waiting)
        #expect(run(1, "completed", "success").state == .passed)
        #expect(run(1, "completed", "failure").state == .failed)
        #expect(run(1, "completed", "timed_out").state == .failed)
        #expect(run(1, "completed", "cancelled").state == .cancelled)
        #expect(run(1, "completed", "skipped").state == .neutral)
    }
}

@Suite struct SummingUpABranch {
    @Test func noRunsMeansNoHeadline() {
        #expect(BranchStatus(runs: []).headline == nil)
    }

    @Test func latestRunWhenAllPassed() {
        let status = BranchStatus(runs: [run(3), run(2), run(1)])
        #expect(status.headline?.id == 3)
        #expect(status.previous == nil)
    }

    @Test func runningRunKeepsThePreviousResult() {
        let status = BranchStatus(runs: [run(3, "in_progress"), run(2, "completed", "failure"), run(1)])
        #expect(status.headline?.id == 3)
        #expect(status.previous?.id == 2)
    }

    @Test func oldFailureFixedSinceDoesNotShow() {
        let status = BranchStatus(runs: [run(3), run(2, "completed", "failure")])
        #expect(status.state == .passed)
    }

    @Test func eachWorkflowCountsWithItsLatestRun() {
        let status = BranchStatus(runs: [
            run(4, workflow: "CodeQL"), run(3, "completed", "failure", workflow: "CI"), run(2, workflow: "CI"),
        ])
        #expect(status.headline?.id == 3)
    }

    @Test func aRunningWorkflowWinsOverAFailedOne() {
        let status = BranchStatus(runs: [
            run(4, "completed", "failure", workflow: "Lint"), run(3, "in_progress", workflow: "CI"),
        ])
        #expect(status.headline?.id == 3)
    }

    @Test func skippedRunsAreIgnored() {
        let status = BranchStatus(runs: [run(3, "completed", "skipped"), run(2, "completed", "failure")])
        #expect(status.headline?.id == 2)
    }
}

@Suite struct OverallIcon {
    let passed = BranchStatus(runs: [run(1)])
    let failed = BranchStatus(runs: [run(2, "completed", "failure")])
    let running = BranchStatus(runs: [run(3, "in_progress")])
    let cancelled = BranchStatus(runs: [run(4, "completed", "cancelled")])

    @Test func emptyAndUnknown() {
        #expect(Overall([]) == .empty)
        #expect(Overall([nil, nil]) == .unknown)
        #expect(Overall([BranchStatus(runs: [])]) == .unknown)
    }

    @Test func greenOnlyWhenNothingFailsOrRuns() {
        #expect(Overall([passed, passed, nil]) == .passed)
        #expect(Overall([passed, cancelled]) == .passed)
    }

    @Test func failureBeatsGreen() {
        #expect(Overall([passed, failed]) == .failed)
    }

    @Test func runningShowsAndRemembersFailures() {
        #expect(Overall([passed, running]) == .running(failing: false))
        #expect(Overall([failed, running]) == .running(failing: true))
    }
}
