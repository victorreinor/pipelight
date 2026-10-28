import AppKit
import EsteiraCore

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
    var now = Date()
}

/// Builds the dropdown: one section per repo with a row per branch, then the actions.
enum MenuBuilder {
    static func items(for model: MenuModel, target: AnyObject?) -> [NSMenuItem] {
        var items: [NSMenuItem] = []

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
            enable.toolTip = "As notificações do Esteira estão desligadas nos Ajustes do Sistema."
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
        items.append(action("Sair do Esteira", #selector(NSApplication.terminate(_:)), key: "q", target: nil))
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

        let title = NSMutableAttributedString(
            string: watched.branch, attributes: [.font: NSFont.menuFont(ofSize: 0).withWeight(.semibold)])
        title.append(NSAttributedString(string: "  \(summary)", attributes: [.font: NSFont.menuFont(ofSize: 0)]))

        let item = action("\(watched.branch)  \(summary)", #selector(StatusController.openLink(_:)), target: target)
        item.attributedTitle = title
        item.image = StatusIcons.row(run?.state, error: state?.error != nil)
        item.representedObject = run?.url ?? watched.actionsURL
        item.toolTip = [run?.workflowName, run?.title, state?.error].compactMap { $0 }.joined(separator: "\n")
        if !detail.isEmpty {
            if #available(macOS 14.4, *) {
                item.subtitle = detail
            } else {
                title.append(NSAttributedString(string: "\n\(detail)", attributes: [
                    .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor,
                ]))
                item.attributedTitle = title
            }
        }
        return item
    }

    /// The menu as plain text, for ESTEIRA_PRINT_MENU.
    static func text(_ items: [NSMenuItem]) -> String {
        items.map { item in
            if item.isSeparatorItem { return "  ────" }
            if item.isSectionHeader { return "[\(item.title)]" }
            let mark = item.state == .on ? "✓ " : "  "
            var line = mark + item.title
            if #available(macOS 14.4, *), let subtitle = item.subtitle {
                line += "\n      \(subtitle)"
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
