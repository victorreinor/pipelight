import Foundation
@testable import PipelightCore

let now = Date(timeIntervalSince1970: 1_800_000_000)

func run(
    _ id: Int, _ status: String = "completed", _ conclusion: String = "success",
    workflow: String = "CI", attempt: Int = 1, minutesAgo: Double = 10, took: Double = 6
) -> WorkflowRun {
    let started = now.addingTimeInterval(-minutesAgo * 60)
    return WorkflowRun(
        id: id, attempt: attempt, workflowName: workflow, title: "commit \(id)", status: status,
        conclusion: status == "completed" ? conclusion : "", createdAt: started, startedAt: started,
        updatedAt: status == "completed" ? started.addingTimeInterval(took * 60) : now,
        url: "https://github.com/acme/api/actions/runs/\(id)")
}
