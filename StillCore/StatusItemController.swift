import AppKit
import Combine
#if !STILLCORE_INTEL
import MacmonSwift
#endif

@MainActor
struct StatusItemDisplayDescriptor {
    let displayName: String
    let persistenceValue: String
    let source: StatusItemDisplaySource

    static let icon = StatusItemDisplayDescriptor(
        displayName: "Icon",
        persistenceValue: "icon",
        source: .icon
    )
}

enum StatusItemDisplaySource {
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
            buildStatusItemMenu(with: metrics)
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

    func formatStatusItemPower(_ value: Double) -> String {
        String(format: "%4.1f W", locale: FormatLocale.posix, value)
    }

    func formatStatusItemTemperature(_ value: Double) -> String {
        String(format: "%2.0f °C", locale: FormatLocale.posix, value)
    }

    func formatStatusItemUsage(_ value: Double) -> String {
        String(format: "%4.1f%%", locale: FormatLocale.posix, value * 100.0)
    }

    private func formatStatusItemPercent(_ value: Double) -> String {
        String(format: "%3.0f%%", locale: FormatLocale.posix, value)
    }

    func formatStatusItemBatteryPercent(_ state: BatteryRuntimeState) -> String? {
        formatStatusItemPercent(state.currentPercent)
    }

    func formatStatusItemFrequency(_ valueGHz: Double) -> String {
        String(format: "%4.2f GHz", locale: FormatLocale.posix, valueGHz)
    }

    func formatStatusItemMemoryGb(_ valueGb: Double) -> String {
        String(format: "%4.1f GB", locale: FormatLocale.posix, valueGb)
    }

    private func buildStatusItemMenu(with metrics: Metrics) {
        displayDescriptors = makeStatusItemDisplayDescriptors(metrics: metrics)
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

}
