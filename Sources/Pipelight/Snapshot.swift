import AppKit
import PipelightCore

/// Development aid behind scripts/screenshots.sh: `PIPELIGHT_SNAPSHOT_DIR=dir Pipelight` renders the README
/// images offscreen and quits (no Screen Recording permission needed). A real NSMenu can't be drawn
/// offscreen, so the dropdown is laid out here, from the items MenuBuilder makes for made-up repos.
@available(macOS 14.4, *)
enum Snapshot {
    static func render(into directory: String) {
        let folder = URL(fileURLWithPath: directory)
        save(hero(), as: .jpeg, to: folder.appendingPathComponent("hero.jpg"))
        save(addPR(), as: .jpeg, to: folder.appendingPathComponent("add-pr.jpg"))
        save(states(), as: .png, to: folder.appendingPathComponent("states.png"))
    }

    // MARK: Made-up data

    private static let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 16, minute: 42, second: 10))!

    private static func run(
        _ id: Int, _ title: String, _ status: String = "completed", _ conclusion: String = "success",
        workflow: String = "CI", minutesAgo: Double, took: Double = 6
    ) -> WorkflowRun {
        let started = now.addingTimeInterval(-minutesAgo * 60)
        return WorkflowRun(
            id: id, workflowName: workflow, title: title, status: status, conclusion: status == "completed" ? conclusion : "",
            createdAt: started, startedAt: started,
            updatedAt: status == "completed" ? started.addingTimeInterval(took * 60) : now)
    }

    private static var model: MenuModel {
        let config = Config(repos: [
            .init(repo: "acme/loja-api", branches: ["master", "homolog"], workflow: "CI"),
            .init(repo: "acme/loja-web", branches: ["master", "homolog"], workflow: "CI"),
            .init(repo: "acme/app-mobile", branches: ["main"]),
        ])
        let runs: [String: [WorkflowRun]] = [
            "acme/loja-api@master": [run(9, "feat(checkout): parcelamento sem juros no cartão (#812)", minutesAgo: 18, took: 7)],
            "acme/loja-api@homolog": [
                run(8, "fix: corrige o cálculo do frete para a região Norte (#815)", "in_progress", minutesAgo: 3),
                run(7, "fix: frete grátis acima de R$ 199", "completed", "failure", minutesAgo: 40, took: 5),
            ],
            "acme/loja-web@master": [run(6, "chore(deps): atualiza o React para a 19.2", minutesAgo: 130, took: 4)],
            "acme/loja-web@homolog": [run(5, "feat: nova vitrine de ofertas na home (#430)", "completed", "failure", minutesAgo: 25, took: 3)],
            "acme/app-mobile@main": [run(4, "fix(ios): crash ao abrir uma notificação push", workflow: "Build", minutesAgo: 26 * 60, took: 14)],
        ]
        var states: [String: BranchState] = [:]
        for target in config.targets {
            states[target.id] = BranchState(status: BranchStatus(runs: runs["\(target.repo)@\(target.branch)"] ?? []))
        }
        return MenuModel(config: config, states: states, lastUpdate: now, isRefreshing: false, configError: nil,
                         notifyPassed: true, opensAtLogin: true, queue: queue, candidates: candidates, now: now)
    }

    /// One PR that just passed (not seen yet: the dot) and one still running.
    private static var queue: [QueuedPR] {
        func pr(_ number: Int, _ title: String, by author: String, _ checks: [Check]) -> PullRequest {
            PullRequest(number: number, title: title, url: "https://github.com/acme/loja-api/pull/\(number)", author: author,
                        headSha: "a\(number)", checks: checks)
        }
        let started = now.addingTimeInterval(-9 * 60)
        var passed = QueuedPR(pr: pr(815, "fix: corrige o cálculo do frete para a região Norte", by: "bia",
                                     [Check(name: "build", workflowName: "CI", status: "IN_PROGRESS", conclusion: "", startedAt: started)]),
                              repo: "acme/loja-api", workflow: "CI", now: now)
        _ = passed.update(with: pr(815, "fix: corrige o cálculo do frete para a região Norte", by: "bia",
                                   [Check(name: "build", workflowName: "CI", startedAt: started, completedAt: now.addingTimeInterval(-2 * 60))]),
                          workflow: "CI")
        let running = QueuedPR(pr: pr(431, "feat: nova vitrine de ofertas na home", by: "caio",
                                      [Check(name: "build", workflowName: "CI", status: "IN_PROGRESS", conclusion: "",
                                             startedAt: now.addingTimeInterval(-5 * 60))]),
                               repo: "acme/loja-web", workflow: "CI", now: now)
        return [passed, running]
    }

    private static var candidates: PRCandidates {
        func candidate(_ repo: String, _ number: Int, _ title: String, by author: String, minutesAgo: Double, draft: Bool = false) -> PRCandidate {
            PRCandidate(ref: PRRef(repo: repo, number: number), title: title, author: author, isDraft: draft,
                        updatedAt: now.addingTimeInterval(-minutesAgo * 60))
        }
        return PRCandidates(
            mine: [
                candidate("acme/loja-api", 812, "feat(checkout): parcelamento sem juros no cartão", by: "voce", minutesAgo: 18),
                candidate("acme/loja-web", 436, "chore: troca o Moment.js pelo date-fns", by: "voce", minutesAgo: 190),
                candidate("acme/app-mobile", 77, "feat: login com a Apple", by: "voce", minutesAgo: 2 * 1440, draft: true),
            ],
            reviewRequested: [
                candidate("acme/loja-api", 815, "fix: corrige o cálculo do frete para a região Norte", by: "bia", minutesAgo: 2),
                candidate("acme/loja-web", 431, "feat: nova vitrine de ofertas na home", by: "caio", minutesAgo: 5),
                candidate("acme/loja-api", 809, "refactor: separa o serviço de cupons do carrinho", by: "duda", minutesAgo: 1440),
            ],
            loadedAt: now)
    }

    // MARK: Scenes

    /// The menu bar with the dropdown open, on a wallpaper.
    private static func hero() -> NSBitmapImageRep {
        let items = MenuBuilder.items(for: model, target: nil)
        let menu = drawnMenu(items, highlighted: items.firstIndex { $0.title.hasPrefix("homolog  quebrou") })
        let size = NSSize(width: 820, height: menu.size.height + 90)
        let barHeight: CGFloat = 30
        return canvas(size) {
            let bounds = NSRect(origin: .zero, size: size)
            drawWallpaper(in: bounds)
            let iconX = size.width - 330
            drawMenuBar(width: size.width, height: barHeight, top: size.height, iconX: iconX,
                        icon: StatusIcons.menuBar(Overall(model.config.targets.map { model.states[$0.id]?.status }), badge: true),
                        open: true)
            // Like macOS, the menu opens under its icon and slides left when it would leave the screen.
            let menuX = min(iconX - 8, size.width - 14 - menu.size.width)
            place(menu, at: NSPoint(x: menuX, y: size.height - barHeight - 6 - menu.size.height))
        }
    }

    /// The "Adicionar PR à fila" submenu on its own.
    private static func addPR() -> NSBitmapImageRep {
        let menu = drawnMenu(MenuBuilder.addPRItems(for: model, target: nil), highlighted: nil)
        let margin: CGFloat = 36
        let size = NSSize(width: menu.size.width + margin * 2, height: menu.size.height + margin * 2)
        return canvas(size) {
            drawWallpaper(in: NSRect(origin: .zero, size: size))
            place(menu, at: NSPoint(x: margin, y: margin + 6))
        }
    }

    /// The four looks of the menu bar icon, each with its caption.
    private static func states() -> NSBitmapImageRep {
        let cases: [(Overall, String, Bool)] = [
            (.passed, "Tudo verde", false),
            (.running(failing: false), "Rodando", false),
            (.running(failing: true), "Rodando, mas algo\nestá quebrado", false),
            (.failed, "Algo quebrou", false),
            (.passed, "Um PR da fila\nterminou", true),
        ]
        let cell = NSSize(width: 190, height: 120)
        let size = NSSize(width: cell.width * CGFloat(cases.count) + 40, height: cell.height + 40)
        return canvas(size) {
            NSColor(white: 0.97, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 18, yRadius: 18).fill()
            for (index, (overall, caption, badge)) in cases.enumerated() {
                let origin = NSPoint(x: 20 + CGFloat(index) * cell.width, y: 20)
                let pill = NSRect(x: origin.x + (cell.width - 64) / 2, y: origin.y + 56, width: 64, height: 40)
                NSColor.white.setFill()
                withShadow(radius: 8, alpha: 0.12) {
                    NSBezierPath(roundedRect: pill, xRadius: 12, yRadius: 12).fill()
                }
                let icon = StatusIcons.menuBar(overall, badge: badge)
                let scale: CGFloat = 1.6
                let iconSize = NSSize(width: icon.size.width * scale, height: icon.size.height * scale)
                icon.draw(in: NSRect(x: pill.midX - iconSize.width / 2, y: pill.midY - iconSize.height / 2,
                                     width: iconSize.width, height: iconSize.height))
                let style = NSMutableParagraphStyle()
                style.alignment = .center
                NSAttributedString(string: caption, attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor(white: 0.25, alpha: 1),
                    .paragraphStyle: style,
                ]).draw(in: NSRect(x: origin.x, y: origin.y - 6, width: cell.width, height: 50))
            }
        }
    }

    // MARK: Menu

    private static let textX: CGFloat = 46

    private static func drawnMenu(_ items: [NSMenuItem], highlighted: Int?) -> NSImage {
        let heights = items.map(rowHeight)
        let padding: CGFloat = 6
        let menuWidth = max(280, items.map(rowWidth).max() ?? 0)
        let size = NSSize(width: menuWidth, height: heights.reduce(0, +) + padding * 2)
        return NSImage(size: size, flipped: true) { rect in
            let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
            NSColor(white: 0.985, alpha: 0.97).setFill()
            shape.fill()
            NSColor(white: 0, alpha: 0.12).setStroke()
            shape.lineWidth = 1
            shape.stroke()
            var y = padding
            for (index, item) in items.enumerated() {
                let row = NSRect(x: 0, y: y, width: menuWidth, height: heights[index])
                drawRow(item, in: row, highlighted: index == highlighted)
                y += heights[index]
            }
            return true
        }
    }

    /// What the row needs: title or subtitle, plus room on the right for a shortcut or submenu arrow.
    private static func rowWidth(_ item: NSMenuItem) -> CGFloat {
        if item.isSeparatorItem || item.isSectionHeader { return 0 }
        let title = (item.attributedTitle ?? text(item.title, size: 13, color: .labelColor)).size().width
        let subtitle = item.subtitle.map { text($0, size: 11, color: .labelColor).size().width } ?? 0
        let trailing: CGFloat = item.keyEquivalent.isEmpty && item.submenu == nil ? 22 : 64
        return ceil(textX + max(title, subtitle) + trailing)
    }

    private static func rowHeight(_ item: NSMenuItem) -> CGFloat {
        if item.isSeparatorItem { return 11 }
        if item.isSectionHeader { return 26 }
        return item.subtitle?.isEmpty == false ? 40 : 24
    }

    private static func drawRow(_ item: NSMenuItem, in row: NSRect, highlighted: Bool) {
        if item.isSeparatorItem {
            NSColor(white: 0, alpha: 0.1).setFill()
            NSRect(x: 14, y: row.midY, width: row.width - 28, height: 1).fill()
            return
        }
        if item.isSectionHeader {
            text(item.title, size: 11, weight: .semibold, color: .secondaryLabelColor).draw(at: NSPoint(x: 14, y: row.minY + 8))
            return
        }
        if highlighted {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: row.insetBy(dx: 5, dy: 0), xRadius: 7, yRadius: 7).fill()
        }
        let primary: NSColor = highlighted ? .white : item.isEnabled ? .labelColor : .tertiaryLabelColor
        let secondary: NSColor = highlighted ? NSColor.white.withAlphaComponent(0.8) : .secondaryLabelColor
        let hasSubtitle = item.subtitle?.isEmpty == false
        let titleY = row.minY + (hasSubtitle ? 4 : 3)
        if item.state == .on {
            text("✓", size: 13, weight: .semibold, color: primary).draw(at: NSPoint(x: 14, y: titleY))
        }
        if let image = item.image {
            image.draw(in: NSRect(x: 24, y: titleY + 1, width: image.size.width, height: image.size.height))
        }
        let title = NSMutableAttributedString(attributedString: item.attributedTitle ?? text(item.title, size: 13, color: primary))
        title.addAttribute(.foregroundColor, value: primary, range: NSRange(location: 0, length: title.length))
        title.draw(at: NSPoint(x: textX, y: titleY))
        if let subtitle = item.subtitle, hasSubtitle {
            text(subtitle, size: 11, color: secondary).draw(at: NSPoint(x: textX, y: titleY + 18))
        }
        if !item.keyEquivalent.isEmpty {
            let key = text("⌘" + item.keyEquivalent.uppercased(), size: 13, color: secondary)
            key.draw(at: NSPoint(x: row.maxX - 16 - key.size().width, y: titleY))
        }
        if item.submenu != nil {
            text("›", size: 15, weight: .semibold, color: secondary).draw(at: NSPoint(x: row.maxX - 24, y: titleY - 2))
        }
    }

    private static func text(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
    }

    // MARK: Menu bar and wallpaper

    private static func drawMenuBar(width: CGFloat, height: CGFloat, top: CGFloat, iconX: CGFloat, icon: NSImage, open: Bool) {
        let bar = NSRect(x: 0, y: top - height, width: width, height: height)
        NSColor(white: 1, alpha: 0.38).setFill()
        bar.fill()
        let ink = NSColor(white: 0.08, alpha: 1)
        text("", size: 15, color: ink).draw(at: NSPoint(x: 18, y: bar.minY + 5))
        var x: CGFloat = 46
        for (index, word) in ["Finder", "Arquivo", "Editar", "Visualizar", "Ir", "Janela", "Ajuda"].enumerated() {
            let label = text(word, size: 13, weight: index == 0 ? .bold : .regular, color: ink)
            label.draw(at: NSPoint(x: x, y: bar.minY + 7))
            x += label.size().width + 18
        }

        if open {
            NSColor(white: 1, alpha: 0.45).setFill()
            NSBezierPath(roundedRect: NSRect(x: iconX - 6, y: bar.minY + 3, width: icon.size.width + 12, height: height - 6),
                         xRadius: 6, yRadius: 6).fill()
        }
        icon.draw(in: NSRect(x: iconX, y: bar.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height))

        x = iconX + icon.size.width + 22
        for name in ["wifi", "battery.75percent", "magnifyingglass", "switch.2"] {
            let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)!
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular).applying(.init(paletteColors: [ink])))!
            symbol.draw(in: NSRect(x: x, y: bar.midY - symbol.size.height / 2, width: symbol.size.width, height: symbol.size.height))
            x += symbol.size.width + 18
        }
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "pt_BR")
        clock.dateFormat = "EEE d 'de' MMM  HH:mm"
        text(clock.string(from: now), size: 13, color: ink).draw(at: NSPoint(x: x + 2, y: bar.minY + 7))
    }

    private static func drawWallpaper(in rect: NSRect) {
        NSGradient(colors: [0x1D3B53, 0x2F6E73, 0x7FB59A, 0xE9D8A6].map(color))!.draw(in: rect, angle: -60)
        for (x, y, radius, hex, alpha) in [(0.9, 0.95, 420.0, 0xFFE3B3, 0.35), (0.05, 0.1, 380.0, 0x5EC4D6, 0.3)] as [(CGFloat, CGFloat, CGFloat, UInt32, CGFloat)] {
            let center = NSPoint(x: rect.width * x, y: rect.height * y)
            NSGradient(colors: [color(hex).withAlphaComponent(alpha), color(hex).withAlphaComponent(0)])!
                .draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
        }
    }

    // MARK: Rendering

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    private static func canvas(_ size: NSSize, scale: CGFloat = 2, draw: () -> Void) -> NSBitmapImageRep {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance(draw)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    private static func place(_ image: NSImage, at origin: NSPoint) {
        withShadow(radius: 24, alpha: 0.3) {
            image.draw(in: NSRect(origin: origin, size: image.size))
        }
    }

    private static func withShadow(radius: CGFloat, alpha: CGFloat, _ draw: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(alpha)
        shadow.shadowBlurRadius = radius
        shadow.shadowOffset = NSSize(width: 0, height: -radius / 3)
        shadow.set()
        draw()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func save(_ bitmap: NSBitmapImageRep, as type: NSBitmapImageRep.FileType, to url: URL) {
        let properties: [NSBitmapImageRep.PropertyKey: Any] = type == .jpeg ? [.compressionFactor: 0.9] : [:]
        do {
            try bitmap.representation(using: type, properties: properties)?.write(to: url)
        } catch {
            NSLog("Pipelight: failed to write \(url.path): \(error)")
        }
    }
}
