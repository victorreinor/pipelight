import AppKit
import PipelightCore

/// Everything the menu shows, so the snapshot can build it from made-up data.
struct MenuModel {
    var config: Config
    var states: [String: BranchState]
    var lastUpdate: Date?
    var isRefreshing: Bool
    var configError: String?
    var notifyPassed: Bool
    var opensAtLogin: Bool
    /// The app may not notify (people said no to macOS's question, or turned it off later).
    var notificationsOff = false
    var queue: [QueuedPR] = []
    var queueErrors: [String: String] = [:]
    var candidates = PRCandidates()
    var now = Date()
}

/// Builds the dropdown: the PR queue, one section per repo with a row per branch, then the actions.
enum MenuBuilder {
    /// Marks the "Adicionar PR à fila" item, whose submenu is refilled each time it opens.
    static let addPRTag = 7001

    static func items(for model: MenuModel, target: AnyObject?) -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        if !model.queue.isEmpty {
            items.append(.sectionHeader(title: "Fila de PRs"))
            for pr in model.queue {
                items.append(queueRow(pr, error: model.queueErrors[pr.ref.id], now: model.now, target: target))
            }
        }
        if model.config.repos.isEmpty {
            items.append(disabled("Nenhum repositório ainda"))
            items.append(disabled("Use \u{201C}Adicionar repositório…\u{201D} abaixo"))
        }
        for repo in model.config.repos {
            items.append(.sectionHeader(title: repo.name))
            for branch in repo.branches {
                let watched = Target(repo: repo.repo, branch: branch, workflow: repo.workflow)
                items.append(row(watched, state: model.states[watched.id], watchingAll: repo.workflow == nil,
                                 now: model.now, target: target))
            }
        }
        items.append(.separator())

        let addPR = NSMenuItem(title: "Adicionar PR à fila", action: nil, keyEquivalent: "")
        addPR.tag = addPRTag
        addPR.submenu = NSMenu()
        addPR.submenu?.autoenablesItems = false
        addPR.submenu?.items = addPRItems(for: model, target: target)
        items.append(addPR)
        if !model.queue.isEmpty {
            let remove = NSMenuItem(title: "Tirar PR da fila", action: nil, keyEquivalent: "")
            remove.submenu = NSMenu()
            remove.submenu?.items = removePRItems(for: model, target: target)
            items.append(remove)
        }
        items.append(.separator())

        items.append(action("Atualizar agora", #selector(StatusController.refreshNow), key: "r", target: target))
        items.append(action("Adicionar repositório…", #selector(StatusController.addRepo), key: "n", target: target))
        if !model.config.repos.isEmpty {
            let remove = NSMenuItem(title: "Remover repositório", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for repo in model.config.repos {
                let item = action(repo.repo, #selector(StatusController.removeRepo(_:)), target: target)
                item.representedObject = repo.repo
                submenu.addItem(item)
            }
            remove.submenu = submenu
            items.append(remove)
        }
        items.append(action("Editar config.json…", #selector(StatusController.editConfig), target: target))
        items.append(.separator())

        if model.notificationsOff {
            let enable = action("Ativar notificações…", #selector(StatusController.openNotificationSettings), target: target)
            enable.image = StatusIcons.symbol("bell.slash.fill", StatusIcons.amber, size: 13)
            enable.toolTip = "As notificações do Pipelight estão desligadas nos Ajustes do Sistema."
            items.append(enable)
        }
        let notify = action("Avisar também quando passar", #selector(StatusController.toggleNotifyPassed), target: target)
        notify.state = model.notifyPassed ? .on : .off
        notify.toolTip = "Quando quebra ou volta a passar, o aviso vem sempre."
        items.append(notify)
        let login = action("Abrir ao iniciar o Mac", #selector(StatusController.toggleOpenAtLogin), target: target)
        login.state = model.opensAtLogin ? .on : .off
        items.append(login)
        items.append(.separator())

        for line in footer(model) {
            items.append(disabled(line))
        }
        items.append(action("Sair do Pipelight", #selector(NSApplication.terminate(_:)), key: "q", target: nil))
        return items
    }

    /// "master · passou em 6 min · há 12 min", with the commit below. Clicking opens the run.
    private static func row(
        _ watched: Target, state: BranchState?, watchingAll: Bool, now: Date, target: AnyObject?
    ) -> NSMenuItem {
        let run = state?.status?.headline
        var summary: String
        var detail: String
        if let run {
            summary = Format.summary(of: run, now: now)
            if run.isActive, let previous = state?.status?.previous {
                summary += previous.state == .failed ? " · antes quebrou" : previous.state == .passed ? " · antes passou" : ""
            }
            detail = Format.truncate(run.title, to: 52)
            if watchingAll && !run.workflowName.isEmpty {
                detail = "\(run.workflowName) · \(detail)"
            }
        } else if let error = state?.error {
            summary = "não consegui ver"
            detail = error
        } else if state?.status != nil {
            summary = "nenhuma execução"
            detail = "nada rodou nesse branch ainda"
        } else {
            summary = "carregando…"
            detail = ""
        }

        let title = boldLead(watched.branch, rest: summary)

        let item = action("\(watched.branch)  \(summary)", #selector(StatusController.openLink(_:)), target: target)
        item.attributedTitle = title
        item.image = StatusIcons.row(run?.state, error: state?.error != nil)
        item.representedObject = run?.url ?? watched.actionsURL
        item.toolTip = [run?.workflowName, run?.title, state?.error].compactMap { $0 }.joined(separator: "\n")
        setDetail(detail, of: item, title: title)
        return item
    }

    // MARK: PR queue

    /// "orodruin-3 #5586  pronto para mergear · master livre", with the PR title and author below.
    /// Clicking opens the PR.
    private static func queueRow(_ pr: QueuedPR, error: String?, now: Date, target: AnyObject?) -> NSMenuItem {
        let summary = Format.summary(of: pr, now: now)
        let title = boldLead(pr.ref.shortName, rest: summary)
        let item = action("\(pr.ref.shortName)  \(summary)", #selector(StatusController.openLink(_:)), target: target)
        item.attributedTitle = title
        item.image = StatusIcons.row(pr.checks, error: error != nil && pr.checks == nil, badge: pr.signal)
        item.representedObject = pr.url
        item.toolTip = [pr.title, error].compactMap { $0 }.joined(separator: "\n")
        setDetail(error ?? [Format.truncate(pr.title, to: 56), pr.author].filter { !$0.isEmpty }.joined(separator: " · "),
                  of: item, title: title)
        return item
    }

    /// The submenu of "Adicionar PR à fila": paste a link, or pick one of your PRs or one asking for
    /// your review. A PR already in the queue shows a check; picking it again takes it out.
    static func addPRItems(for model: MenuModel, target: AnyObject?) -> [NSMenuItem] {
        var items = [action("Colar link do PR…", #selector(StatusController.pastePRLink), target: target)]
        let candidates = model.candidates
        guard candidates.loadedAt != nil else {
            items.append(.separator())
            items.append(disabled(candidates.error.map { "⚠︎ \($0)" } ?? "Carregando PRs…"))
            return items
        }
        let queued = Set(model.queue.map(\.ref.id))
        for (header, list, showAuthor) in [
            ("Seus PRs abertos", candidates.mine, false),
            ("Pedindo revisão (você ou seu time)", candidates.reviewRequested, true),
        ] {
            items.append(.sectionHeader(title: header))
            if list.isEmpty {
                items.append(disabled("Nenhum"))
            }
            for candidate in list {
                // Titles often share a long prefix ("Projeto - Implementação <> …"), so the title gets
                // the wider second line and the short facts go up front.
                let facts = [Format.ago(candidate.updatedAt, now: model.now), showAuthor ? candidate.author : nil,
                             candidate.isDraft ? "rascunho" : nil].compactMap { $0 }.joined(separator: " · ")
                let title = boldLead(candidate.ref.shortName, rest: facts)
                let item = action("\(candidate.ref.shortName)  \(facts)", #selector(StatusController.toggleQueuedPR(_:)),
                                  target: target)
                item.attributedTitle = title
                item.representedObject = "\(candidate.ref.repo)#\(candidate.ref.number)"
                item.state = queued.contains(candidate.ref.id) ? .on : .off
                item.toolTip = candidate.title
                setDetail(Format.truncate(candidate.title, to: 60), of: item, title: title)
                items.append(item)
            }
        }
        if let error = candidates.error {
            items.append(disabled("⚠︎ \(error)"))
        }
        return items
    }

    private static func removePRItems(for model: MenuModel, target: AnyObject?) -> [NSMenuItem] {
        var items = model.queue.map { pr in
            let item = action("\(pr.ref.shortName)  \(Format.truncate(pr.title, to: 36))",
                              #selector(StatusController.removeQueuedPR(_:)), target: target)
            item.representedObject = pr.ref.id
            return item
        }
        items.append(.separator())
        if model.queue.contains(where: { $0.checks == .passed }) {
            items.append(action("Tirar os que já passaram", #selector(StatusController.removePassedPRs), target: target))
        }
        items.append(action("Esvaziar a fila", #selector(StatusController.clearQueue), target: target))
        return items
    }

    // MARK: Pieces

    /// "master  passou…" with the first part in semibold. No colors: the menu's blue highlight
    /// wouldn't invert them.
    private static func boldLead(_ lead: String, rest: String) -> NSMutableAttributedString {
        let title = NSMutableAttributedString(string: lead, attributes: [.font: NSFont.menuFont(ofSize: 0).withWeight(.semibold)])
        title.append(NSAttributedString(string: "  \(rest)", attributes: [.font: NSFont.menuFont(ofSize: 0)]))
        return title
    }

    /// The gray second line: `subtitle` on macOS 14.4+, else a second line of the title.
    private static func setDetail(_ detail: String, of item: NSMenuItem, title: NSMutableAttributedString) {
        guard !detail.isEmpty else { return }
        if #available(macOS 14.4, *) {
            item.subtitle = detail
        } else {
            title.append(NSAttributedString(string: "\n\(detail)", attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            item.attributedTitle = title
        }
    }

    /// The menu as plain text, submenus indented, for PIPELIGHT_PRINT_MENU.
    static func text(_ items: [NSMenuItem], indent: String = "") -> String {
        items.map { item in
            if item.isSeparatorItem { return indent + "  ────" }
            if item.isSectionHeader { return indent + "[\(item.title)]" }
            let mark = item.state == .on ? "✓ " : "  "
            var line = indent + mark + item.title
            if #available(macOS 14.4, *), let subtitle = item.subtitle {
                line += "\n\(indent)      \(subtitle)"
            }
            if let submenu = item.submenu {
                line += " ›\n" + text(submenu.items, indent: indent + "      ")
            }
            return line
        }.joined(separator: "\n")
    }

    private static func footer(_ model: MenuModel) -> [String] {
        var lines: [String] = []
        if let error = model.configError {
            lines.append("⚠︎ \(error)")
        }
        let errors = Set(model.states.values.compactMap(\.error))
        if errors.count == 1, let error = errors.first {
            lines.append("⚠︎ \(error)")
        } else if errors.count > 1 {
            lines.append("⚠︎ alguns repositórios não responderam")
        }
        if model.isRefreshing {
            lines.append("Atualizando…")
        } else if let lastUpdate = model.lastUpdate {
            lines.append("Atualizado às \(lastUpdate.formatted(date: .omitted, time: .standard))")
        }
        return lines
    }

    private static func action(_ title: String, _ selector: Selector, key: String = "", target: AnyObject?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = target
        return item
    }

    private static func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: pointSize, weight: weight)
    }
}
