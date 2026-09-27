import AppKit
import SwiftUI

struct BatteryEnergyModeMenuAnchor: NSViewRepresentable {
    var controller: BatteryEnergyModeMenuController
    var batteryState: BatteryRuntimeState
    var openBatterySettings: () -> Void

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        controller.anchorView = nsView
        controller.batteryState = batteryState
        controller.openBatterySettings = openBatterySettings
    }
}

@MainActor
final class BatteryEnergyModeMenuController: NSObject {
    weak var anchorView: NSView?
    var batteryState: BatteryRuntimeState?
    var openBatterySettings: (() -> Void)?
    private let popUpCell: NSPopUpButtonCell = {
        let cell = NSPopUpButtonCell(textCell: "", pullsDown: false)
        cell.altersStateOfSelectedItem = false
        cell.arrowPosition = .noArrow
        cell.isBordered = false
        cell.isBezeled = false
        return cell
    }()

    func showMenu() {
        guard let anchorView, let batteryState else { return }
        let menu = menu(for: batteryState)
        let selectedItem = menu.item(
            withTag: batteryState.batteryStatus.powerSaveMode ? EnergyModeTag.powerSave : EnergyModeTag.automatic
        )
        popUpCell.menu = menu
        popUpCell.select(selectedItem)
        var cellFrame = anchorView.bounds
        if #available(macOS 27.0, *) {
            cellFrame = cellFrame.offsetBy(dx: 6, dy: -1)  // Borderless
        } else if #available(macOS 26.0, *) {
            // cellFrame = cellFrame.offsetBy(dx: 1, dy: 1)  // Bordered
            cellFrame = cellFrame.offsetBy(dx: 5, dy: -1)  // Borderless
        } else {
            // cellFrame = cellFrame.offsetBy(dx: -5, dy: 1)  // Bordered
            cellFrame = cellFrame.offsetBy(dx: 2, dy: 3)  // Borderless
        }
        popUpCell.performClick(withFrame: cellFrame, in: anchorView)
    }

    private func menu(for batteryState: BatteryRuntimeState) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem.sectionHeader(title: "Energy Mode"))
        menu.addItem(makeEnergyModeItem(
            title: "Automatic", state: batteryState, powerSaveMode: false, tag: EnergyModeTag.automatic
        ))
        menu.addItem(makeEnergyModeItem(
            title: "Power Save", state: batteryState, powerSaveMode: true, tag: EnergyModeTag.powerSave
        ))
        menu.addItem(.separator())
        let batterySettingsItem = NSMenuItem(
            title: "Battery Settings...",
            action: #selector(openBatterySettings(_:)),
            keyEquivalent: ""
        )
        batterySettingsItem.target = self
        menu.addItem(batterySettingsItem)
        return menu
    }

    private func makeEnergyModeItem(
        title: String,
        state: BatteryRuntimeState,
        powerSaveMode: Bool,
        tag: Int
    ) -> NSMenuItem {
        var menuState = state
        menuState.batteryStatus.powerSaveMode = powerSaveMode
        let item = NSMenuItem(title: title, action: #selector(selectEnergyMode(_:)), keyEquivalent: "")
        item.target = self
        item.tag = tag
        item.state = .off
        item.image = BatteryIndicatorImage.make(state: menuState, usesSecondaryMask: false)
        return item
    }

    @objc private func selectEnergyMode(_ sender: NSMenuItem) {
        guard let batteryState else { return }

        let lowPowerMode: String
        switch sender.tag {
        case EnergyModeTag.automatic:
            lowPowerMode = "0"
        case EnergyModeTag.powerSave:
            lowPowerMode = "1"
        default:
            return
        }

        let powerSource = batteryState.batteryStatus.isOnACPower ? "-c" : "-b"
        let command = EnergyModeCommand(arguments: [powerSource, "lowpowermode", lowPowerMode])

        Task {
            if await Self.runEnergyModeCommand(command).isSudoFailure {
                if continueSudoersAlert() {
                    if await Self.runEnergyModeCommand(command).isSudoFailure {
                        _ = await Self.runSudoersInstallScript(Self.sudoersInstallScript(), retrying: command)
                    }
                }
            }
        }
    }

    @objc private func openBatterySettings(_ sender: NSMenuItem) {
        openBatterySettings?()
    }

    private enum EnergyModeTag {
        static let automatic = 1
        static let powerSave = 2
    }

    private struct EnergyModeCommand: Sendable {
        let arguments: [String]

        var displayText: String {
            (["/usr/bin/sudo", "-n", "/usr/bin/pmset"] + arguments).joined(separator: " ")
        }
    }

    private struct EnergyModeCommandResult: Sendable {
        let command: EnergyModeCommand
        let exitCode: Int32
        let output: String

        var isSudoFailure: Bool {
            exitCode == 1 && output.hasPrefix("sudo: ")
        }
    }

    private struct SudoersInstallResult: Sendable {
        let exitCode: Int32
        let output: String

        var isUserCancelled: Bool {
            exitCode == 1 && output.contains("(-128)")
        }
    }

    private nonisolated static func runEnergyModeCommand(
        _ command: EnergyModeCommand
    ) async -> EnergyModeCommandResult {
        await Task.detached {
            let process = Process()
            let pipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["-n", "/usr/bin/pmset"] + command.arguments
            process.standardOutput = pipe
            process.standardError = pipe

            let result: EnergyModeCommandResult
            do {
                try process.run()
                process.waitUntilExit()
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                result = EnergyModeCommandResult(
                    command: command,
                    exitCode: process.terminationStatus,
                    output: output
                )
            } catch {
                result = EnergyModeCommandResult(
                    command: command,
                    exitCode: -1,
                    output: error.localizedDescription
                )
            }

            if result.exitCode != 0 {
                if !result.isSudoFailure {
                    await MainActor.run {
                        showCommandFailureAlert(
                            title: "Energy Mode update failed",
                            command: result.command.displayText,
                            output: result.output
                        )
                    }
                }
                return result
            }

            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return result
            }
            await MainActor.run {
                BatteryTrackerService.shared.refreshRuntimeState()
            }
            return result
        }.value
    }

    private nonisolated static func runSudoersInstallScript(
        _ script: String,
        retrying command: EnergyModeCommand
    ) async -> SudoersInstallResult {
        await Task.detached {
            let process = Process()
            let pipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = [
                "-e",
                "do shell script \"\(script)\" with administrator privileges",
            ]
            process.standardOutput = pipe
            process.standardError = pipe

            let result: SudoersInstallResult
            do {
                try process.run()
                process.waitUntilExit()
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                result = SudoersInstallResult(exitCode: process.terminationStatus, output: output)
            } catch {
                result = SudoersInstallResult(exitCode: -1, output: error.localizedDescription)
            }

            if result.exitCode != 0 {
                if !result.isUserCancelled {
                    await MainActor.run {
                        showCommandFailureAlert(
                            title: "Permission setup failed",
                            command: sudoersInstallCommand(),
                            output: result.output
                        )
                    }
                }
                return result
            }

            _ = await runEnergyModeCommand(command)
            return result
        }.value
    }

    private func continueSudoersAlert() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Need permission to change Energy Mode"
        alert.informativeText = "StillCore will run this command, or you can run it manually in Terminal:"
        alert.accessoryView = makeCommandAccessoryView(command: Self.sudoersInstallCommand())
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func showCommandFailureAlert(title: String, command: String, output: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = """
        Command:
        \(command)

        Output:
        \(output.isEmpty ? "No output." : output)
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func sudoersInstallCommand() -> String {
        "sudo sh -c \"\(sudoersInstallScript())\""
    }

    private static func sudoersInstallScript() -> String {
        let sudoersLine = "\(NSUserName()) ALL=(root) NOPASSWD: /usr/bin/pmset -[bc] lowpowermode [01]"
        let sudoersPath = "/etc/sudoers.d/stillcore-\(getuid())"
        return "echo '\(sudoersLine)' > \(sudoersPath) && chmod 440 \(sudoersPath)"
    }

    private func makeCommandAccessoryView(command: String) -> NSView {
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

}

private final class SelectingCommandTextField: NSTextField {
    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else {
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
