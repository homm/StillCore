import AppKit

enum SudoersPermissionAlert {
    enum InstallResult: Sendable, Equatable {
        case success
        case cancelled
        case failure(String)
    }

    @MainActor
    static func confirm(title: String, rule: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "StillCore will run this command, or you can run it manually in Terminal:"
        alert.accessoryView = commandView(command(rule: rule))
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func destination(uid: uid_t = getuid(), directory: String = "/etc/sudoers.d") -> String {
        "\(directory)/stillcore-\(uid)"
    }

    static func script(
        rule: String,
        uid: uid_t = getuid(),
        directory: String = "/etc/sudoers.d"
    ) -> String {
        let path = destination(uid: uid, directory: directory)
        return "echo \(shellQuote(rule)) >> \(path) && chmod 440 \(path)"
    }

    static func command(
        rule: String,
        uid: uid_t = getuid(),
        directory: String = "/etc/sudoers.d"
    ) -> String {
        let path = destination(uid: uid, directory: directory)
        return [
            "sudo sh -c \"",
            "  echo \(shellQuote(rule)) \\",
            "    >> \(path) &&",
            "  chmod 440 \(path)",
            "\"",
        ].joined(separator: "\n")
    }

    private static func appleScriptQuoted(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func install(
        rule: String,
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/osascript")
    ) async -> InstallResult {
        await Task.detached {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = executableURL
            process.arguments = [
                "-e",
                "do shell script \"\(appleScriptQuoted(script(rule: rule)))\" with administrator privileges",
            ]
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if process.terminationStatus == 0 { return .success }
                if process.terminationStatus == 1 && output.contains("(-128)") { return .cancelled }
                return .failure(output)
            } catch {
                return .failure(error.localizedDescription)
            }
        }.value
    }

    @MainActor
    private static func commandView(_ command: String) -> NSView {
        let width: CGFloat = 320
        let textField = SelectingCommandTextField(wrappingLabelWithString: command)

        textField.frame.size.width = width
        textField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textField.alignment = .left
        textField.drawsBackground = true
        textField.isSelectable = true
        textField.lineBreakMode = .byWordWrapping
        textField.maximumNumberOfLines = 0
        textField.cell?.wraps = true
        textField.cell?.usesSingleLineMode = false
        textField.frame.size.height = ceil(textField.cell?.cellSize(forBounds: NSRect(
            x: 0, y: 0, width: width, height: .greatestFiniteMagnitude
        )).height ?? 100)

        return textField
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

}

private final class SelectingCommandTextField: NSTextField {
    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        if !super.becomeFirstResponder() {
            return false
        }

        if let editor = currentEditor() {
            editor.perform(#selector(NSText.selectAll(_:)), with: self, afterDelay: 0.0)
        }
        return true
    }

    override func mouseDown(with event: NSEvent) {
        currentEditor()?.selectAll(nil)
    }
}
