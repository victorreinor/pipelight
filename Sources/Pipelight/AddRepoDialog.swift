import AppKit

/// "Adicionar repositório…": an alert with three fields. The caller checks the answer with gh and
/// asks again, with the problem on top, until it works or people cancel.
@MainActor
enum AddRepoDialog {
    struct Input {
        var repo = ""
        var branches = ""
        var workflow = ""
    }

    static func ask(_ input: Input, problem: String?) -> Input? {
        let alert = NSAlert()
        alert.messageText = "Adicionar repositório"
        alert.informativeText = problem ?? "Cole o endereço do repositório no GitHub ou escreva dono/nome."
        alert.alertStyle = problem == nil ? .informational : .warning
        alert.addButton(withTitle: "Adicionar")
        alert.addButton(withTitle: "Cancelar")

        let repo = field(input.repo, placeholder: "dono/nome ou https://github.com/dono/nome")
        let branches = field(input.branches, placeholder: "o padrão do repo (ou: main, homolog)")
        let workflow = field(input.workflow, placeholder: "todos (ou o nome, ex.: CI)")
        let grid = NSGridView(views: [
            [label("Repositório"), repo],
            [label("Branches"), branches],
            [label("Workflow"), workflow],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.frame = NSRect(origin: .zero, size: NSSize(width: 400, height: grid.fittingSize.height))
        alert.accessoryView = grid
        alert.window.initialFirstResponder = repo

        // The app has no windows of its own; without this the alert opens behind the frontmost app.
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return Input(repo: repo.stringValue, branches: branches.stringValue, workflow: workflow.stringValue)
    }

    private static func field(_ value: String, placeholder: String) -> NSTextField {
        let field = NSTextField(string: value)
        field.placeholderString = placeholder
        field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        return field
    }

    private static func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }
}
