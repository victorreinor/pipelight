import Foundation
import Testing
@testable import PipelightCore

private func job(
    _ name: String, _ status: String = "COMPLETED", _ conclusion: String = "SUCCESS",
    workflow: String? = "CI", started: Double = 10, finished: Double? = 4
) -> Check {
    Check(name: name, workflowName: workflow, status: status, conclusion: status == "COMPLETED" ? conclusion : "",
          startedAt: now.addingTimeInterval(-started * 60),
          completedAt: status == "COMPLETED" ? finished.map { now.addingTimeInterval(-$0 * 60) } : nil)
}

private func pr(_ checks: [Check], sha: String = "a1", state: String = "OPEN", base: String = "master") -> PullRequest {
    PullRequest(number: 42, title: "feat: vitrine", url: "https://github.com/acme/api/pull/42", author: "ana",
                state: state, baseBranch: base, headSha: sha, checks: checks)
}

/// The base branch with a deploy going on, or after it ended.
private let busy = BranchStatus(runs: [run(9, "in_progress", minutesAgo: 3), run(8, minutesAgo: 60)])
private let free = BranchStatus(runs: [run(9, minutesAgo: 20, took: 15)])
private let broken = BranchStatus(runs: [run(9, "completed", "failure", minutesAgo: 20, took: 15)])

@Suite struct DecodingPullRequests {
    @Test func decodesPrViewWithJobsAndCommitStatuses() throws {
        let json = """
        {"number":5586,"title":"Melhoria","url":"https://github.com/acme/api/pull/5586","state":"OPEN","isDraft":false,
         "author":{"login":"ana"},"baseRefName":"master","headRefOid":"88d1",
         "statusCheckRollup":[
          {"__typename":"CheckRun","name":"build","workflowName":"CI","status":"IN_PROGRESS","conclusion":"",
           "startedAt":"2026-10-28T19:49:27Z","completedAt":"0001-01-01T00:00:00Z"},
          {"__typename":"StatusContext","context":"AWS CodeBuild","state":"PENDING","startedAt":"2026-10-28T19:49:27Z"}
         ]}
        """
        let pr = try PullRequest.decode(Data(json.utf8))
        #expect(pr.author == "ana")
        #expect(pr.headSha == "88d1")
        #expect(pr.baseBranch == "master")
        #expect(pr.isOpen)
        #expect(pr.checks.map(\.state) == [.running, .running])
        #expect(pr.checks[0].completedAt == nil)
        #expect(pr.checks[1].name == "AWS CodeBuild")
        #expect(pr.checks[1].workflowName == nil)
    }

    @Test func nullRollupMeansNoChecks() throws {
        let json = #"{"number":1,"title":"x","state":"MERGED","author":{"login":"ana"},"headRefOid":"b","statusCheckRollup":null}"#
        let pr = try PullRequest.decode(Data(json.utf8))
        #expect(pr.checks.isEmpty)
        #expect(!pr.isOpen)
    }

    @Test func decodesSearchResults() throws {
        let json = """
        [{"author":{"login":"ana"},"isDraft":true,"number":7,"repository":{"name":"api","nameWithOwner":"acme/api"},
          "title":"WIP","updatedAt":"2026-10-28T19:36:59Z"}]
        """
        let candidates = try PRCandidate.decodeList(Data(json.utf8))
        #expect(candidates.first?.ref == PRRef(repo: "acme/api", number: 7))
        #expect(candidates.first?.isDraft == true)
    }
}

@Suite struct SummingUpChecks {
    @Test func noChecksYet() {
        #expect(ChecksSummary(checks: [], workflow: nil).state == nil)
    }

    @Test func runningBeatsFailedUntilEverythingEnds() {
        #expect(ChecksSummary(checks: [job("a", "COMPLETED", "FAILURE"), job("b", "IN_PROGRESS")], workflow: nil).state == .running)
        #expect(ChecksSummary(checks: [job("a", "COMPLETED", "FAILURE"), job("b")], workflow: nil).state == .failed)
    }

    @Test func skippedJobsDontBlockAPass() {
        let summary = ChecksSummary(checks: [job("a"), job("b", "COMPLETED", "SKIPPED")], workflow: nil)
        #expect(summary.state == .passed)
        #expect(summary.finishedAt == now.addingTimeInterval(-4 * 60))
    }

    @Test func onlyTheWatchedWorkflowCounts() {
        let checks = [job("lint", "COMPLETED", "FAILURE", workflow: "Fieldnews patterns"), job("build", workflow: "Continuous integration"),
                      Check(name: "AWS CodeBuild", status: "IN_PROGRESS", conclusion: "")]
        #expect(ChecksSummary(checks: checks, workflow: "continuous integration").state == .passed)
        #expect(ChecksSummary(checks: checks, workflow: nil).state == .running)
    }

    @Test func workflowFileNameCannotFilterSoEverythingCounts() {
        let checks = [job("build", workflow: "CI"), job("lint", "COMPLETED", "FAILURE", workflow: "Lint")]
        #expect(ChecksSummary(checks: checks, workflow: "ci.yml").state == .failed)
    }

    @Test func watchedWorkflowNotStartedYetMeansWaiting() {
        #expect(ChecksSummary(checks: [job("lint", workflow: "Lint")], workflow: "CI").state == nil)
    }

    @Test func aReRunReplacesTheOlderEntryOfTheSameJob() {
        let checks = [job("build", "COMPLETED", "CANCELLED", started: 20, finished: 19), job("build", started: 10, finished: 4)]
        #expect(ChecksSummary(checks: checks, workflow: nil).state == .passed)
    }

    @Test func allCancelled() {
        #expect(ChecksSummary(checks: [job("a", "COMPLETED", "CANCELLED")], workflow: nil).state == .cancelled)
    }
}

@Suite struct WatchingAQueuedPR {
    private func queued(_ checks: [Check], base: BranchStatus?) -> QueuedPR {
        QueuedPR(pr: pr(checks), repo: "acme/api", workflow: nil, baseStatus: base, now: now)
    }

    @Test func waitsWhileTheBaseBranchRuns() {
        var queued = queued([job("build", "IN_PROGRESS")], base: busy)
        #expect(queued.signal == nil)
        // The PR's own CI finishing doesn't matter while the deploy goes on.
        #expect(queued.update(with: pr([job("build")]), baseStatus: busy, workflow: nil) == nil)
        #expect(queued.signal == nil)
    }

    @Test func theBaseGettingFreeIsAnnouncedOnceWithThePRsState() throws {
        var queued = queued([job("build")], base: busy)
        let notice = queued.update(with: pr([job("build")]), baseStatus: free, workflow: nil)
        let freed = try #require(notice)
        #expect(freed.title == "✅ api · master passou")
        #expect(freed.subtitle == "#42 pronto para mergear")
        #expect(freed.body == "feat: vitrine")
        #expect(freed.url == "https://github.com/acme/api/pull/42")
        #expect(freed.fromQueue)
        #expect(queued.signal == .ready)
        #expect(queued.update(with: pr([job("build")]), baseStatus: free, workflow: nil) == nil)
        #expect(queued.signal == .ready)
    }

    @Test func aBrokenDeployIsAnnouncedToo() {
        var queued = queued([job("build")], base: busy)
        let freed = queued.update(with: pr([job("build")]), baseStatus: broken, workflow: nil)
        #expect(freed?.kind == .failed)
        #expect(freed?.title == "❌ api · master quebrou")
        #expect(freed?.subtitle == "#42 pronto para mergear")
    }

    @Test func freeWhileThePRsCIStillRunsThenReady() throws {
        var queued = queued([job("build", "IN_PROGRESS")], base: busy)
        let freed = queued.update(with: pr([job("build", "IN_PROGRESS")]), baseStatus: free, workflow: nil)
        #expect(freed?.subtitle == "#42: CI do PR ainda rodando")
        #expect(queued.signal == .checksRunning)
        let notice = queued.update(with: pr([job("build")]), baseStatus: free, workflow: nil)
        let ready = try #require(notice)
        #expect(ready.title == "✅ api #42 pronto para mergear")
        #expect(ready.subtitle == "master livre · CI em 6 min")
        #expect(queued.signal == .ready)
    }

    @Test func freeWithThePRsCIBroken() {
        var queued = queued([job("build", "IN_PROGRESS")], base: busy)
        let freed = queued.update(with: pr([job("build", "COMPLETED", "FAILURE")]), baseStatus: free, workflow: nil)
        #expect(freed?.subtitle == "#42: CI do PR quebrou")
        #expect(queued.signal == .checksFailed)
        // Already told in the notice above.
        #expect(queued.update(with: pr([job("build", "COMPLETED", "FAILURE")]), baseStatus: free, workflow: nil) == nil)
    }

    @Test func thePRsCIBreakingWhileTheBaseIsFree() {
        var queued = queued([job("build", "IN_PROGRESS")], base: free)
        let notice = queued.update(with: pr([job("build", "COMPLETED", "FAILURE")]), baseStatus: free, workflow: nil)
        #expect(notice?.kind == .failed)
        #expect(notice?.title == "❌ api #42: CI do PR quebrou")
    }

    @Test func anotherDeployTurnsTheDotOffUntilItEnds() {
        var queued = queued([job("build")], base: free)
        #expect(queued.signal == .ready)
        #expect(queued.update(with: pr([job("build")]), baseStatus: busy, workflow: nil) == nil)
        #expect(queued.signal == nil)
        #expect(queued.update(with: pr([job("build")]), baseStatus: free, workflow: nil)?.subtitle == "#42 pronto para mergear")
    }

    @Test func addingAPRToAFreeBranchAnnouncesNothing() {
        var queued = queued([job("build")], base: free)
        #expect(queued.signal == .ready)
        #expect(queued.update(with: pr([job("build")]), baseStatus: free, workflow: nil) == nil)
    }

    @Test func aBaseSeenForTheFirstTimeAnnouncesNothing() {
        var queued = queued([job("build")], base: nil)
        #expect(queued.signal == nil)
        #expect(queued.update(with: pr([job("build")]), baseStatus: free, workflow: nil) == nil)
        #expect(queued.signal == .ready)
    }

    @Test func anUnknownBaseKeepsTheLastLook() {
        var queued = queued([job("build")], base: busy)
        #expect(queued.update(with: pr([job("build")]), baseStatus: nil, workflow: nil) == nil)
        #expect(queued.baseBusy == true)
        #expect(queued.update(with: pr([job("build")]), baseStatus: free, workflow: nil) != nil)
    }

    @Test func retargetingForgetsTheOldBase() {
        var queued = queued([job("build")], base: busy)
        #expect(queued.update(with: pr([job("build")], base: "homolog"), baseStatus: free, workflow: nil) == nil)
        #expect(queued.base == "homolog")
        #expect(queued.signal == .ready)
    }

    @Test func aNewPushIsAnnouncedAgainAndCanBeAFix() {
        var queued = queued([job("build", "COMPLETED", "FAILURE")], base: free)
        #expect(queued.update(with: pr([job("build", "IN_PROGRESS")], sha: "b2"), baseStatus: free, workflow: nil) == nil)
        #expect(queued.signal == .checksRunning)
        let notice = queued.update(with: pr([job("build")], sha: "b2"), baseStatus: free, workflow: nil)
        #expect(notice?.kind == .fixed)
        #expect(notice?.title == "✅ api #42 pronto para mergear")
        #expect(notice?.subtitle == "master livre · CI voltou a passar em 6 min")
    }

    @Test func theMenuBarShowsTheMostActionableDot() {
        let running = queued([job("build", "IN_PROGRESS")], base: free)
        let failed = queued([job("build", "COMPLETED", "FAILURE")], base: free)
        let ready = queued([job("build")], base: free)
        let waiting = queued([job("build")], base: busy)
        #expect(QueuedPR.Signal.strongest(in: [waiting]) == nil)
        #expect(QueuedPR.Signal.strongest(in: [running, waiting]) == .checksRunning)
        #expect(QueuedPR.Signal.strongest(in: [running, failed]) == .checksFailed)
        #expect(QueuedPR.Signal.strongest(in: [failed, ready, running]) == .ready)
    }

    @Test func savesAndLoads() throws {
        let queued = queued([job("build", "IN_PROGRESS")], base: busy)
        let data = try JSONEncoder().encode([queued])
        #expect(try JSONDecoder().decode([QueuedPR].self, from: data) == [queued])
    }

    @Test func loadsAQueueSavedBeforeTheBaseBranch() throws {
        let json = """
        [{"addedAt":814915914,"announced":"a1:passed","author":"ana","checks":"passed","finishedAt":814875318,"headSha":"a1",
          "ref":{"number":42,"repo":"acme/api"},"startedAt":814874390,"title":"feat: vitrine","unseen":false,
          "url":"https://github.com/acme/api/pull/42"}]
        """
        var queued = try #require(try JSONDecoder().decode([QueuedPR].self, from: Data(json.utf8)).first)
        #expect(queued.base == nil)
        #expect(queued.update(with: pr([job("build")], sha: "a1"), baseStatus: free, workflow: nil) == nil)
        #expect(queued.signal == .ready)
    }

    @Test func summaryTexts() {
        var queued = queued([job("build", "IN_PROGRESS", started: 4)], base: nil)
        #expect(Format.summary(of: queued, now: now) == "CI rodando há 4 min")
        _ = queued.update(with: pr([job("build", started: 10, finished: 2)]), baseStatus: busy, workflow: nil)
        #expect(Format.summary(of: queued, now: now) == "esperando o master · CI passou há 2 min")
        _ = queued.update(with: pr([job("build", started: 10, finished: 2)]), baseStatus: free, workflow: nil)
        #expect(Format.summary(of: queued, now: now) == "pronto para mergear · master livre")
        _ = queued.update(with: pr([job("build", "IN_PROGRESS", started: 4)], sha: "b2"), baseStatus: free, workflow: nil)
        #expect(Format.summary(of: queued, now: now) == "master livre · CI rodando há 4 min")
        #expect(Format.summary(of: self.queued([], base: nil), now: now) == "esperando os checks")
    }
}

@Suite struct FindingPRLinks {
    @Test(arguments: [
        "https://github.com/acme/api/pull/42", "https://github.com/acme/api/pull/42/files", "github.com/acme/api/pull/42#discussion",
        "olha esse aqui: https://github.com/acme/api/pull/42 quando der", "acme/api#42", "<https://github.com/acme/api/pull/42|acme/api#42>",
    ])
    func finds(_ text: String) {
        #expect(PRRef.find(in: text) == PRRef(repo: "acme/api", number: 42))
    }

    @Test(arguments: ["", "https://github.com/acme/api/issues/42", "https://github.com/acme/api", "#42", "veja o PR 42"])
    func ignores(_ text: String) {
        #expect(PRRef.find(in: text) == nil)
    }

    @Test func names() {
        let ref = PRRef(repo: "Acme/orodruin-3", number: 5586)
        #expect(ref.shortName == "orodruin-3 #5586")
        #expect(ref.id == "acme/orodruin-3#5586")
        #expect(ref.url == "https://github.com/Acme/orodruin-3/pull/5586")
    }
}
