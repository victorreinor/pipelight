import AppKit

/// "Colar link do PR…": an alert with one field. People paste with ⌘V, which macOS always allows;
/// reading the clipboard on our own would make macOS ask "Pipelight wants to paste" every time.
@MainActor
enum AddPRDialog {
    static func ask(_ text: String, problem: String?) -> String? {
        let alert = NSAlert()
        alert.messageText = "Adicionar PR à fila"
        alert.informativeText = problem ?? "Cole (⌘V) o link do PR. Quando o CI dele terminar, o Pipelight avisa."
        alert.alertStyle = problem == nil ? .informational : .warning
        alert.addButton(withTitle: "Adicionar")
        alert.addButton(withTitle: "Cancelar")

        let field = NSTextField(string: text)
        field.placeholderString = "https://github.com/dono/repo/pull/123"
        field.frame = NSRect(x: 0, y: 0, width: 380, height: field.fittingSize.height)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        // The app has no windows of its own; without this the alert opens behind the frontmost app.
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}
