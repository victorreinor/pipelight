import Foundation
import Testing
@testable import PipelightCore

@Suite struct ConfigFile {
    @Test func decodesAndFlattensTargets() throws {
        let json = """
        {"repos": [
          {"repo": "acme/api", "branches": ["master", "homolog"], "workflow": "Continuous integration"},
          {"repo": "acme/web", "branches": ["main"], "workflow": "  "},
          {"repo": "acme/app"}
        ]}
        """
        let config = try Config.decode(Data(json.utf8))
        #expect(config.targets.map(\.id) == [
            "acme/api@master#Continuous integration", "acme/api@homolog#Continuous integration",
            "acme/web@main#", "acme/app@main#",
        ])
        #expect(config.repos[1].workflow == nil)
        #expect(config.repos[0].name == "api")
    }

    @Test func roundTrips() throws {
        let config = Config(repos: [.init(repo: "acme/api", branches: ["master"], workflow: "CI")])
        #expect(try Config.decode(config.encoded()) == config)
    }

    @Test func emptyFileShapeIsFine() throws {
        #expect(try Config.decode(Data("{}".utf8)).repos.isEmpty)
    }

    @Test func ghArguments() {
        #expect(Target(repo: "acme/api", branch: "master", workflow: "CI").ghArguments == [
            "run", "list", "--repo", "acme/api", "--branch", "master", "--limit", "5", "--json", WorkflowRun.ghFields,
            "--workflow", "CI",
        ])
        #expect(Target(repo: "acme/api", branch: "master").ghArguments.contains("20"))
    }

    @Test func actionsURL() {
        #expect(Target(repo: "acme/api", branch: "feat/x").actionsURL == "https://github.com/acme/api/actions?query=branch:feat/x")
    }
}

@Suite struct ParsingWhatPeoplePaste {
    @Test(arguments: [
        "acme/api", " acme/api ", "https://github.com/acme/api", "https://github.com/acme/api/actions/runs/1",
        "github.com/acme/api", "git@github.com:acme/api.git", "https://github.com/acme/api.git", "www.github.com/acme/api/",
    ])
    func repo(_ input: String) {
        #expect(RepoInput.parse(input) == "acme/api")
    }

    @Test(arguments: ["", "acme", "acme/", "acme api/x y", "https://github.com/acme"])
    func notARepo(_ input: String) {
        #expect(RepoInput.parse(input) == nil)
    }

    @Test func branches() {
        #expect(RepoInput.branches("master, homolog") == ["master", "homolog"])
        #expect(RepoInput.branches(" master homolog,master ") == ["master", "homolog"])
        #expect(RepoInput.branches("  ").isEmpty)
    }
}

@Suite struct Texts {
    @Test func ago() {
        #expect(Format.ago(now.addingTimeInterval(-20), now: now) == "agora")
        #expect(Format.ago(now.addingTimeInterval(-12 * 60), now: now) == "há 12 min")
        #expect(Format.ago(now.addingTimeInterval(-3 * 3600), now: now) == "há 3 h")
        #expect(Format.ago(now.addingTimeInterval(-30 * 3600), now: now) == "há 1 dia")
        #expect(Format.ago(now.addingTimeInterval(-80 * 3600), now: now) == "há 3 dias")
        #expect(Format.ago(now.addingTimeInterval(60), now: now) == "agora")
    }

    @Test func duration() {
        #expect(Format.duration(42) == "42 s")
        #expect(Format.duration(6 * 60 + 30) == "6 min")
        #expect(Format.duration(3600) == "1 h")
        #expect(Format.duration(3600 + 5 * 60) == "1 h 05 min")
    }

    @Test func truncate() {
        #expect(Format.truncate("curto", to: 20) == "curto")
        #expect(Format.truncate("feat: agrupamento de OSs por localização", to: 24) == "feat: agrupamento de…")
        #expect(Format.truncate("linha 1\nlinha 2", to: 20) == "linha 1")
    }

    @Test func summary() {
        #expect(Format.summary(of: run(1, "in_progress", minutesAgo: 4), now: now) == "rodando há 4 min")
        #expect(Format.summary(of: run(1, minutesAgo: 20, took: 6), now: now) == "passou em 6 min · há 14 min")
        #expect(Format.summary(of: run(1, "completed", "failure", minutesAgo: 20, took: 6), now: now) == "quebrou em 6 min · há 14 min")
    }
}

@Suite struct PollingRules {
    @Test func intervals() {
        #expect(Polling.interval(targets: 7, running: false) == 30)
        #expect(Polling.interval(targets: 7, running: true) == 15)
        #expect(Polling.interval(targets: 50, running: true) == 90)
    }

    @Test func explainsGhErrors() {
        #expect(Polling.explain("could not find any workflows named nope") == "workflow não encontrado nesse repositório")
        #expect(Polling.explain("failed to get runs: HTTP 404: Not Found (https://…)") == "repositório não encontrado (ou sem acesso)")
        #expect(Polling.explain("To get started with GitHub CLI, please run:  gh auth login") == "gh sem login: rode gh auth login no Terminal")
        #expect(Polling.explain("error connecting to api.github.com") == "sem conexão com o GitHub")
        #expect(Polling.explain("algo estranho\nmais") == "algo estranho")
    }
}
