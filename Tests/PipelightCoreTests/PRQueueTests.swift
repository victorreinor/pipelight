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

private func pr(_ checks: [Check], sha: String = "a1", state: String = "OPEN") -> PullRequest {
    PullRequest(number: 42, title: "feat: vitrine", url: "https://github.com/acme/api/pull/42", author: "ana",
                state: state, headSha: sha, checks: checks)
}

@Suite struct DecodingPullRequests {
    @Test func decodesPrViewWithJobsAndCommitStatuses() throws {
        let json = """
        {"number":5586,"title":"Melhoria","url":"https://github.com/acme/api/pull/5586","state":"OPEN","isDraft":false,
         "author":{"login":"ana"},"headRefOid":"88d1",
         "statusCheckRollup":[
          {"__typename":"CheckRun","name":"build","workflowName":"CI","status":"IN_PROGRESS","conclusion":"",
           "startedAt":"2026-10-28T19:49:27Z","completedAt":"0001-01-01T00:00:00Z"},
          {"__typename":"StatusContext","context":"AWS CodeBuild","state":"PENDING","startedAt":"2026-10-28T19:49:27Z"}
         ]}
        """
        let pr = try PullRequest.decode(Data(json.utf8))
        #expect(pr.author == "ana")
        #expect(pr.headSha == "88d1")
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
    @Test func addingAFinishedPRAnnouncesNothing() {
        var queued = QueuedPR(pr: pr([job("build")]), repo: "acme/api", workflow: nil, now: now)
        #expect(queued.checks == .passed)
        #expect(queued.update(with: pr([job("build")]), workflow: nil) == nil)
        #expect(!queued.unseen)
    }

    @Test func announcesOnceWhenChecksFinish() throws {
        var queued = QueuedPR(pr: pr([job("build", "IN_PROGRESS")]), repo: "acme/api", workflow: nil, now: now)
        #expect(queued.update(with: pr([job("build", "IN_PROGRESS")]), workflow: nil) == nil)
        let finished = queued.update(with: pr([job("build")]), workflow: nil)
        let notice = try #require(finished)
        #expect(notice.title == "✅ api #42 passou")
        #expect(notice.subtitle == "PR de ana · CI em 6 min")
        #expect(notice.body == "feat: vitrine")
        #expect(notice.fromQueue)
        #expect(queued.unseen)
        #expect(queued.update(with: pr([job("build")]), workflow: nil) == nil)
    }

    @Test func failureIsAnnounced() {
        var queued = QueuedPR(pr: pr([job("build", "IN_PROGRESS")]), repo: "acme/api", workflow: nil, now: now)
        let notice = queued.update(with: pr([job("build", "COMPLETED", "FAILURE")]), workflow: nil)
        #expect(notice?.kind == .failed)
        #expect(notice?.title == "❌ api #42 quebrou")
    }

    @Test func aNewPushIsAnnouncedAgainAndCanBeAFix() {
        var queued = QueuedPR(pr: pr([job("build", "COMPLETED", "FAILURE")], sha: "a1"), repo: "acme/api", workflow: nil, now: now)
        #expect(queued.update(with: pr([job("build", "IN_PROGRESS")], sha: "b2"), workflow: nil) == nil)
        #expect(queued.checks == .running)
        let notice = queued.update(with: pr([job("build")], sha: "b2"), workflow: nil)
        #expect(notice?.kind == .fixed)
        #expect(notice?.title == "✅ api #42 voltou a passar")
    }

    @Test func savesAndLoads() throws {
        let queued = QueuedPR(pr: pr([job("build", "IN_PROGRESS")]), repo: "acme/api", workflow: nil, now: now)
        let data = try JSONEncoder().encode([queued])
        #expect(try JSONDecoder().decode([QueuedPR].self, from: data) == [queued])
    }

    @Test func summaryTexts() {
        var queued = QueuedPR(pr: pr([job("build", "IN_PROGRESS", started: 4)]), repo: "acme/api", workflow: nil, now: now)
        #expect(Format.summary(of: queued, now: now) == "rodando há 4 min")
        _ = queued.update(with: pr([job("build", started: 10, finished: 2)]), workflow: nil)
        #expect(Format.summary(of: queued, now: now) == "passou · há 2 min")
        #expect(Format.summary(of: QueuedPR(pr: pr([]), repo: "acme/api", workflow: nil, now: now), now: now) == "esperando os checks")
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
