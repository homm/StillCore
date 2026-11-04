import AppKit
import Combine
import MacmonSwift

@MainActor
private struct StatusItemDisplayDescriptor {
    let displayName: String
    let persistenceValue: String
    let source: StatusItemDisplaySource

    static let icon = StatusItemDisplayDescriptor(
        displayName: "Icon",
        persistenceValue: "icon",
        source: .icon
    )
}

private enum StatusItemDisplaySource {
    case icon
    case metrics((Metrics) -> Double?, (Double) -> String)
    case batteryIcon
    case batteryStatus((BatteryRuntimeState) -> String?)
}

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private var statusMetricsSubscription: AnyCancellable?
    private var statusBatterySubscription: AnyCancellable?
    private var lastMetrics: Metrics?
    private var lastBatteryState: BatteryRuntimeState?
    private var displayDescriptors: [StatusItemDisplayDescriptor] = []
    private var selectedDisplayDescriptor = StatusItemDisplayDescriptor.icon

    init(statusItem: NSStatusItem, menu: NSMenu) {
        self.statusItem = statusItem
        self.menu = menu
        super.init()

        configureStatusItem()

        statusMetricsSubscription = AppDependencies.shared.metricsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] metrics in
                self?.updateStatusItemMetrics(metrics)
            }

        statusBatterySubscription = BatteryTrackerService.shared.runtimeStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateStatusItemBatteryState(state)
            }
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = nil
        button.font = AppFonts.statusItemButton
        button.toolTip = AppPresentation.statusItemToolTip
        applyStatusItemIcon(to: statusItem)
    }

    private func updateStatusItemMetrics(_ metrics: Metrics) {
        lastMetrics = metrics
        if displayDescriptors.isEmpty {
            buildStatusItemMenu()
            applyStatusItemDisplayMode(AppSettings.statusItemDisplayMode ?? "icon")
        } else {
            applyStatusItemMetrics(to: statusItem)
        }
    }

    private func updateStatusItemBatteryState(_ state: BatteryRuntimeState?) {
        lastBatteryState = state
        switch selectedDisplayDescriptor.source {
        case .batteryIcon:
            applyStatusItemBatteryIcon(to: statusItem)
        case .batteryStatus:
            applyStatusItemBatteryState(to: statusItem)
        case .icon, .metrics:
            return
        }
    }

    private func formatStatusItemPower(_ value: Double) -> String {
        String(format: "%4.1f W", value)
    }

    private func formatStatusItemTemperature(_ value: Double) -> String {
        String(format: "%2.0f °C", value)
    }

    private func formatStatusItemUsage(_ value: Double) -> String {
        String(format: "%4.1f%%", value * 100.0)
    }

    private func formatStatusItemBatteryPercent(_ state: BatteryRuntimeState) -> String? {
        String(format: "%3d%%", state.displayedPercent)
    }

    private func formatStatusItemMemoryGb(_ valueGb: Double) -> String {
        String(format: "%4.1f GB", valueGb)
    }

    private func buildStatusItemMenu() {
        displayDescriptors = makeStatusItemDisplayDescriptors()
        menu.insertItem(.separator(), at: 0)
        for descriptor in displayDescriptors.reversed() {
            let item = NSMenuItem(
                title: descriptor.displayName,
                action: #selector(selectStatusItemDisplayMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = descriptor.persistenceValue
            menu.insertItem(item, at: 0)
        }
    }

    private func applyStatusItemMetrics(to statusItem: NSStatusItem) {
        guard case .metrics(let getValue, let formatValue) = selectedDisplayDescriptor.source else {
            return
        }
        guard let lastMetrics, let value = getValue(lastMetrics) else {
            applyStatusItemIcon(to: statusItem)
            return
        }
        applyStatusItemTitle(formatValue(value), to: statusItem)
    }

    private func applyStatusItemBatteryState(to statusItem: NSStatusItem) {
        guard case .batteryStatus(let formatValue) = selectedDisplayDescriptor.source else {
            return
        }
        guard let lastBatteryState, let title = formatValue(lastBatteryState) else {
            applyStatusItemIcon(to: statusItem)
            return
        }
        applyStatusItemTitle(title, to: statusItem)
    }

    private func applyStatusItemBatteryIcon(to statusItem: NSStatusItem) {
        guard let lastBatteryState else {
            applyStatusItemIcon(to: statusItem)
            return
        }

        let image = BatteryIndicatorImage.make(
            state: lastBatteryState,
            usesSecondaryMask: true
        )
        applyStatusItemImage(image, to: statusItem)
    }

    private func applyStatusItemIcon(to statusItem: NSStatusItem) {
        let image = NSImage(
            systemSymbolName: AppPresentation.statusItemSystemImageName,
            accessibilityDescription: AppPresentation.statusItemToolTip
        )
        image?.isTemplate = true
        applyStatusItemImage(image, to: statusItem)
    }

    private func applyStatusItemImage(_ image: NSImage?, to statusItem: NSStatusItem) {
        guard let button = statusItem.button else { return }
        button.image = image
        button.title = ""
    }

    private func applyStatusItemTitle(_ title: String, to statusItem: NSStatusItem) {
        guard let button = statusItem.button else { return }
        let leadingSpaces = title.prefix { $0 == " " }
        let remainingTitle = title.dropFirst(leadingSpaces.count).replacingOccurrences(of: " ", with: "\u{2006}")
        let displayTitle = String(repeating: "\u{2007}", count: leadingSpaces.count) + remainingTitle
        if button.image != nil {
            button.image = nil
        }
        if button.title != displayTitle {
            button.title = displayTitle
        }
    }

    private func applyStatusItemDisplayMode(_ persistenceValue: String) {
        let selectedStatusItemDisplayMode =
            displayDescriptors.contains { $0.persistenceValue == persistenceValue }
            ? persistenceValue
            : "icon"
        selectedDisplayDescriptor =
            displayDescriptors.first { $0.persistenceValue == selectedStatusItemDisplayMode }
            ?? .icon
        AppSettings.statusItemDisplayMode = selectedDisplayDescriptor.persistenceValue
        for item in menu.items {
            guard let persistenceValue = item.representedObject as? String else { continue }
            item.state = persistenceValue == selectedDisplayDescriptor.persistenceValue ? .on : .off
        }

        switch selectedDisplayDescriptor.source {
        case .metrics:
            applyStatusItemMetrics(to: statusItem)
        case .batteryIcon:
            applyStatusItemBatteryIcon(to: statusItem)
        case .batteryStatus:
            applyStatusItemBatteryState(to: statusItem)
        case .icon:
            applyStatusItemIcon(to: statusItem)
        }
    }

    @objc private func selectStatusItemDisplayMode(_ sender: NSMenuItem) {
        guard let persistenceValue = sender.representedObject as? String else { return }
        applyStatusItemDisplayMode(persistenceValue)
    }

    private func makeStatusItemDisplayDescriptors() -> [StatusItemDisplayDescriptor] {
        var descriptors = [StatusItemDisplayDescriptor.icon]
        let cpuTierWeights: [Double] = AppDependencies.shared.socInfo?.cpuTiers.map {
            let maxFrequency = Double($0.freqs.max() ?? 0)
            // Squared frequency is a heuristic for faster tiers doing more work per clock,
            // so fully busy efficiency cores contribute less to the overall CPU load.
            return Double($0.cores) * maxFrequency * maxFrequency
        } ?? []
        let totalCPUWeight = cpuTierWeights.reduce(0, +)

        if BatteryTrackerService.isBatteryAvailable {
            descriptors += [
                StatusItemDisplayDescriptor(
                    displayName: "Battery percent",
                    persistenceValue: "batteryPercent",
                    source: .batteryStatus(formatStatusItemBatteryPercent)
                ),
                StatusItemDisplayDescriptor(
                    displayName: "Battery icon",
                    persistenceValue: "batteryIcon",
                    source: .batteryIcon
                ),
            ]
        }

        descriptors += [
            StatusItemDisplayDescriptor(
                displayName: "System power",
                persistenceValue: "systemPower",
                source: .metrics(
                    { metrics in Double(metrics.sysPower) },
                    formatStatusItemPower
                )
            ),
            StatusItemDisplayDescriptor(
                displayName: "Chip power",
                persistenceValue: "chipPower",
                source: .metrics(
                    { metrics in Double(metrics.chipPower) },
                    formatStatusItemPower
                )
            ),
            StatusItemDisplayDescriptor(
                displayName: "CPU power",
                persistenceValue: "cpuPower",
                source: .metrics(
                    { metrics in Double(metrics.cpuPower) },
                    formatStatusItemPower
                )
            ),
            StatusItemDisplayDescriptor(
                displayName: "Temperature",
                persistenceValue: "maxTemperature",
                source: .metrics(
                    { metrics in
                        Double(max(metrics.temp.cpuTempAvg, metrics.temp.gpuTempAvg))
                    },
                    formatStatusItemTemperature
                )
            ),
            StatusItemDisplayDescriptor(
                displayName: "CPU load",
                persistenceValue: "totalCpuLoad",
                source: .metrics(
                    { metrics in
                        if totalCPUWeight == 0 { return Double(metrics.cpuActiveRatio) }
                        let weightedUsage = zip(metrics.cpuTiers, cpuTierWeights).reduce(0.0) {
                            $0 + Double($1.0.activeRatio) * $1.1
                        }
                        return weightedUsage / totalCPUWeight
                    },
                    formatStatusItemUsage
                )
            ),
            StatusItemDisplayDescriptor(
                displayName: "RAM used",
                persistenceValue: "ramUsed",
                source: .metrics(
                    { metrics in Double(metrics.memory.ramUsage) / 1_073_741_824.0 },
                    formatStatusItemMemoryGb
                )
            ),
            StatusItemDisplayDescriptor(
                displayName: "RAM load",
                persistenceValue: "ramLoad",
                source: .metrics(
                    { metrics in
                        guard metrics.memory.ramTotal > 0 else { return 0 }
                        return Double(metrics.memory.ramUsage) / Double(metrics.memory.ramTotal)
                    },
                    formatStatusItemUsage
                )
            ),
            StatusItemDisplayDescriptor(
                displayName: "Swap used",
                persistenceValue: "swapUsed",
                source: .metrics(
                    { metrics in Double(metrics.memory.swapUsage) / 1_073_741_824.0 },
                    formatStatusItemMemoryGb
                )
            ),
        ]

        return descriptors
    }
}
