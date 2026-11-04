import SwiftUI
import Darwin
import Combine

private final class ProcessMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(performAction), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    @objc private func performAction() { handler() }
}

private struct ProcessMenuButton: NSViewRepresentable {
    let label: String
    let makeMenu: () -> NSMenu?
    var select: (() -> Void)? = nil

    final class RowButton: NSButton {
        var makeMenu: (() -> NSMenu?)?
        var select: (() -> Void)?

        override func menu(for event: NSEvent) -> NSMenu? {
            select?()
            return makeMenu?()
        }

        @objc func activate() {
            if let select {
                select()
            } else {
                makeMenu?()?.popUp(positioning: nil, at: NSPoint(x: bounds.minX, y: bounds.maxY), in: self)
            }
        }
    }

    func makeNSView(context: Context) -> RowButton {
        let button = RowButton()
        button.title = ""
        button.isBordered = false
        if select == nil {
            button.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
        }
        button.target = button
        button.action = #selector(RowButton.activate)
        return button
    }

    func updateNSView(_ button: RowButton, context: Context) {
        button.makeMenu = makeMenu
        button.isEnabled = context.environment.isEnabled
        button.select = select
        button.setAccessibilityLabel(label)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RowButton, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 20, height: 22))
    }
}

struct ProcessList: View {
    @ObservedObject var presentationState: MenuPresentationState
    let processPublisher: AnyPublisher<[ProcessReading], Never>
    let isExpanded: Bool

    private enum Column: String, CaseIterable {
        case cpu = "CPU"
        case gpu = "GPU"
        case memory = "Memory"
        case power = "Power"

        var width: CGFloat {
            switch self {
            case .cpu: 36
            case .memory: 62
            case .gpu, .power: 48
            }
        }

        var color: Color {
            switch self {
            case .cpu: Color(nsColor: MetricsChartPalette.cpu)
            case .gpu: Color(nsColor: MetricsChartPalette.gpu)
            case .memory: .primary
            case .power: Color(nsColor: MetricsChartPalette.packageText)
            }
        }
    }

    @State private var readings: [ProcessReading] = []
    @State private var sortColumn = Column.power
    @State private var selectedProcessID: ProcessReading.ID?
    @State private var errorMessage: String?

    private var sortedReadings: [ProcessReading] {
        readings.sorted { lhs, rhs in
            let left = value(lhs, column: sortColumn)
            let right = value(rhs, column: sortColumn)
            if left != right {
                if let left, let right {
                    return left > right
                }
                return left != nil
            }
            return lhs.id.pid < rhs.id.pid
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            if isExpanded {
                processTable
                    .padding(.horizontal, -6)
                    .padding(.top, 8)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: isExpanded) { _, expanded in
            if !expanded {
                selectedProcessID = nil
            }
            AppDependencies.shared.setProcessesVisible(expanded && presentationState.isWindowVisible)
            readings = []
        }
        .onReceive(presentationState.$isWindowVisible) { visible in
            AppDependencies.shared.setProcessesVisible(isExpanded && visible)
            readings = []
        }
        .onDisappear {
            AppDependencies.shared.setProcessesVisible(false)
        }
        .onReceive(processPublisher) { sample in
            readings = sample
            if let selectedProcessID, !sample.isEmpty,
               !sample.contains(where: { $0.id == selectedProcessID }) {
                self.selectedProcessID = nil
            }
        }
    }

    private var processTable: some View {
        var topReadings = Array(sortedReadings.prefix(7))
        let selectedProcess = readings.first { $0.id == selectedProcessID }
        if let selectedProcess,
           !topReadings.contains(where: { $0.id == selectedProcess.id }) {
            topReadings = Array(topReadings.prefix(6)) + [selectedProcess]
        }
        let cpuFont = sortColumn == .cpu ? AppFonts.chartLegend : AppFonts.processValue
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let names = topReadings.map { $0.displayName(using: &path) }
        let selectedIndex = topReadings.firstIndex { $0.id == selectedProcessID }
        let cpuWidth = topReadings.reduce(Column.cpu.width) { width, process in
            let text = process.cpu.map { String(format: "%.1f%%", $0) } ?? "—"
            return max(width, ceil((text as NSString).size(withAttributes: [.font: cpuFont]).width))
        }
        return VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text("Process")
                    .frame(maxWidth: .infinity, alignment: .leading)
                ProcessMenuButton(label: selectedIndex.map { "Actions for \(names[$0])" } ?? "Process actions") {
                    selectedIndex.map { processMenu(for: topReadings[$0], name: names[$0]) }
                }
                .frame(width: 20, height: 22)
                .disabled(selectedProcess == nil)
                ForEach(Column.allCases, id: \.self) { column in
                    Button {
                        sortColumn = column
                    } label: {
                        Text(column.rawValue)
                        .frame(height: 22)
                        .foregroundStyle(column.color)
                        .background {
                            if sortColumn == column {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(column.color.opacity(0.12))
                                    .padding(.horizontal, -6)
                            }
                        }
                        .frame(width: column == .cpu ? cpuWidth : column.width, alignment: .trailing)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Sort by \(column.rawValue)")
                    .accessibilityValue(sortColumn == column ? "Selected" : "")
                    .help("Sort by \(column.rawValue)")
                }
            }
            .padding(.horizontal, 6)
            .foregroundStyle(.secondary)
            Divider()
                .padding(.vertical, 3)

            ForEach(Array(topReadings.enumerated()), id: \.element.id) { index, process in
                processRow(process, name: names[index], shaded: !index.isMultiple(of: 2), cpuWidth: cpuWidth)
            }
            if readings.isEmpty {
                Text("Sampling processes…")
                    .foregroundStyle(.secondary)
                    .frame(height: 22)
            }
            if let errorMessage {
                HStack(alignment: .top) {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                    Spacer()
                    Button("Dismiss") { self.errorMessage = nil }
                }
            }
        }
        .font(Font(AppFonts.chartLegend))
    }

    private func processRow(_ process: ProcessReading, name: String, shaded: Bool, cpuWidth: CGFloat) -> some View {
        let selected = selectedProcessID == process.id
        return ZStack {
            ProcessMenuButton(label: name, makeMenu: { processMenu(for: process, name: name) }) {
                selectedProcessID = process.id
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityAddTraits(selected ? [.isSelected] : [])

            HStack(spacing: 4) {
                Text(name)
                    .foregroundStyle(process.isBackground ? Color(nsColor: .secondaryLabelColor) : selected ? Color(nsColor: .selectedTextColor) : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .allowsHitTesting(false)
                ForEach(Column.allCases, id: \.self) { column in
                    let metric = formatted(process, column: column, selected: selected)
                    metric.text
                        .font(Font(AppFonts.processValue))
                        .fontWeight(sortColumn == column ? .medium : .regular)
                        .foregroundStyle(
                            selected ? Color(nsColor: .selectedTextColor) : metric.isMuted
                                ? Color(nsColor: .tertiaryLabelColor)
                                : .primary
                        )
                        .allowsHitTesting(false)
                        .lineLimit(1)
                        .frame(width: column == .cpu ? cpuWidth : column.width, alignment: .trailing)
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 6)
            .frame(height: 22)
        }
        .frame(height: 22)
        .background {
            RoundedRectangle(cornerRadius: 4)
                .fill(selected ? Color(nsColor: .selectedTextBackgroundColor).opacity(0.60) : Color.primary.opacity(shaded ? 0.035 : 0))
        }
        .help("\(name) (PID \(process.id.pid))")
    }

    private func processMenu(for process: ProcessReading, name: String) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(NSMenuItem.sectionHeader(title: "\(name) (PID \(process.id.pid))"))
        let policy = process.externalBackgroundPolicy
        let background = ProcessMenuItem("Background task policy") {
            if let policy {
                do {
                    try process.setBackgroundPolicy(!policy)
                } catch {
                    errorMessage = "Could not change background policy for \(name): \(error.localizedDescription)"
                }
            }
        }
        background.isEnabled = policy != nil
        background.state = policy == true ? .on : .off
        menu.addItem(background)
        menu.addItem(.separator())
        menu.addItem(ProcessMenuItem("Terminate…") {
            confirmTermination(of: process, name: name, force: false)
        })
        let forceKill = ProcessMenuItem("Force Kill…") {
            confirmTermination(of: process, name: name, force: true)
        }
        forceKill.attributedTitle = NSAttributedString(string: forceKill.title, attributes: [.foregroundColor: NSColor.systemRed])
        menu.addItem(forceKill)
        return menu
    }

    private func confirmTermination(of process: ProcessReading, name: String, force: Bool) {
        let action = force ? "Force Kill" : "Terminate"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = force ? "Force kill process?" : "Terminate process?"
        alert.informativeText = "\(name) (PID \(process.id.pid))\nUnsaved changes may be lost."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: action).hasDestructiveAction = true
        if presentationState.mode == .attached {
            alert.window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        }
        presentationState.isConfirmingProcessTermination = true
        let response = alert.runModal()
        presentationState.isConfirmingProcessTermination = false
        if response == .alertSecondButtonReturn {
            do {
                try process.send(signal: force ? SIGKILL : SIGTERM)
            } catch {
                errorMessage = "Could not \(action.lowercased()) \(name): \(error.localizedDescription)"
            }
        }
    }

    private func value(_ process: ProcessReading, column: Column) -> Double? {
        switch column {
        case .cpu: process.cpu
        case .gpu: process.gpu
        case .memory: Double(process.memory)
        case .power: process.power
        }
    }

    private func formatted(_ process: ProcessReading, column: Column, selected: Bool) -> (text: Text, isMuted: Bool) {
        if let value = value(process, column: column) {
            switch column {
            case .cpu, .gpu, .power:
                let number = String(format: column == .power ? "%.2f" : "%.1f", value)
                let isMuted = number == "0.0" || number == "0.00"
                let unit = Text(column == .power ? " W" : "%")
                    .foregroundColor(Color(nsColor: selected ? .selectedTextColor : isMuted ? .tertiaryLabelColor : .secondaryLabelColor))
                return (Text(number) + unit, isMuted)
            case .memory:
                var bytes = Int64(process.memory)
                let megabyte: Int64 = 1_048_576
                if bytes >= megabyte && bytes < 1_073_741_824 {
                    bytes = ((bytes + megabyte / 2) / megabyte) * megabyte
                }
                let parts = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
                    .split(separator: " ", maxSplits: 1)
                let amount = Text(parts[0])
                if parts.count == 2 {
                    return (amount + Text(" \(parts[1])").foregroundColor(selected ? Color(nsColor: .selectedTextColor) : .secondary), process.memory == 0)
                }
                return (amount, process.memory == 0)
            }
        }
        return (Text("—"), true)
    }
}
