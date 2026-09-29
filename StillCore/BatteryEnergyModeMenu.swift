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
                let rule = Self.sudoersLine
                if SudoersPermissionAlert.confirm(
                    title: "Need permission to change Energy Mode",
                    rule: rule
                ) {
                    if await Self.runEnergyModeCommand(command).isSudoFailure {
                        switch await SudoersPermissionAlert.install(rule: rule) {
                        case .success:
                            _ = await Self.runEnergyModeCommand(command)
                        case .cancelled:
                            break
                        case .failure(let output):
                            Self.showCommandFailureAlert(
                                title: "Permission setup failed",
                                command: SudoersPermissionAlert.command(rule: rule),
                                output: output
                            )
                        }
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
                BatteryTrackerService.shared.refresh()
            }
            return result
        }.value
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

    private static var sudoersLine: String {
        "\(NSUserName()) ALL=(root) NOPASSWD: /usr/bin/pmset -[bc] lowpowermode [01]"
    }
}
