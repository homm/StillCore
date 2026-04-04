import AppKit
import Combine
import SwiftUI
import MacmonSwift

enum AppSettings {
    static let defaultMetricsIntervalMs = 2000
    private static let metricsIntervalKey = "metricsIntervalMs"
    private static let statusItemDisplayModeKey = "statusItemDisplayMode"

    static var metricsIntervalMs: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: metricsIntervalKey)
            return value == 0 ? defaultMetricsIntervalMs : value
        }
        set {
            UserDefaults.standard.set(newValue, forKey: metricsIntervalKey)
        }
    }

    static var statusItemDisplayMode: String? {
        get {
            UserDefaults.standard.string(forKey: statusItemDisplayModeKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: statusItemDisplayModeKey)
        }
    }
}

enum AppPresentation {
    static let windowMinSize = CGSize(width: 420, height: 560)
    static let statusItemSystemImageName = "chart.bar.xaxis"
    static let statusItemFallbackTitle = "Core"
    static let statusItemToolTip = "StillCore"
    static let pinnedWindowTitle = "StillCore"
    static let chartHistoryCapacity = 180
}

enum FormatLocale {
    static let posix = Locale(identifier: "en_US_POSIX")
}

// MARK: - DI

@MainActor
final class AppDependencies: ObservableObject {
    static let shared = AppDependencies()

    @Published var chipName: String?
    @Published var socSummary: String = ""
    @Published var metricsError: String = ""
    private var metricsTask: Task<Void, Never>?
    private let metricsSubject = PassthroughSubject<Metrics, Never>()

    var metricsPublisher: AnyPublisher<Metrics, Never> {
        metricsSubject.eraseToAnyPublisher()
    }

    private init() {
        startMetricsLoop()
        loadSocInfo()
    }

    func startMetricsLoop() {
        guard metricsTask == nil else { return }
        metricsError = ""

        metricsTask = Task.detached {
            let clock = ContinuousClock()
            var lastUpdateStarted = clock.now

            do {
                let sampler = try Sampler()
                defer { sampler.close() }

                while !Task.isCancelled {
                    while true {
                        let intervalMs = await MainActor.run { AppDependencies.shared.metricsIntervalMs }
                        let sampleInterval = Swift.Duration.milliseconds(intervalMs)
                        let elapsed = lastUpdateStarted.duration(to: clock.now)
                        guard elapsed < sampleInterval else { break }

                        do {
                            try await Task.sleep(for: min(sampleInterval - elapsed, .milliseconds(500)))
                        } catch {
                            break
                        }
                    }

                    guard !Task.isCancelled else { break }
                    lastUpdateStarted = clock.now

                    let metrics = try sampler.metrics()
                    await MainActor.run {
                        AppDependencies.shared.metricsSubject.send(metrics)
                        if !AppDependencies.shared.metricsError.isEmpty {
                            AppDependencies.shared.metricsError = ""
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    AppDependencies.shared.metricsError = "Macmon metrics error: \(error)"
                    AppDependencies.shared.metricsTask = nil
                }
            }
        }
    }

    private func loadSocInfo() {
        do {
            let info = try Macmon.socInfo()
            chipName = info.chipName
            socSummary = formatSocSummary(info)
        } catch {
            chipName = nil
            socSummary = ""
        }
    }

    private func formatSocSummary(_ info: SocInfo) -> String {
        var parts = info.cpuDomains.compactMap { domain -> String? in
            var name = domain.name.uppercased()
            let lower = domain.name.lowercased()
            if lower == "ecpu" {
                name = "E"
            }
            if lower == "pcpu" {
                name = "P"
            }
            return "\(domain.units)\(name)"
        }
        parts.append("\(info.gpuCores)G cores")
        return parts.joined(separator: " ")
    }

    @Published var metricsIntervalMs: Int = AppSettings.metricsIntervalMs {
        didSet {
            AppSettings.metricsIntervalMs = metricsIntervalMs
        }
    }

    func increaseMetricsInterval() {
        let current = metricsIntervalMs
        let step =
            current >= Self.largeIntervalThresholdMs
            ? Self.largeIntervalStepMs : Self.intervalStepMs
        metricsIntervalMs = min(
            ((metricsIntervalMs + step) / step) * step, Self.maxMetricsIntervalMs)
    }

    func decreaseMetricsInterval() {
        let step =
            metricsIntervalMs > Self.largeIntervalThresholdMs
            ? Self.largeIntervalStepMs : Self.intervalStepMs
        metricsIntervalMs = max(
            (max(metricsIntervalMs - step, 0) + step - 1) / step * step, Self.minMetricsIntervalMs)
    }

    private static let minMetricsIntervalMs = 100
    private static let maxMetricsIntervalMs = 10_000
    private static let intervalStepMs = 250
    private static let largeIntervalStepMs = 1_000
    private static let largeIntervalThresholdMs = 5_000
}

private enum MetricsChartPalette {
    static let board = Color(red: 0.12, green: 0.8, blue: 0.2)
    static let package = Color(red: 0.13, green: 0.48, blue: 0.97)
    static let cpu = Color(red: 0.32, green: 0.74, blue: 0.98)
    static let gpu = Color(red: 1, green: 0.22, blue: 0.02)
    static let ane = Color(red: 0.98, green: 0.58, blue: 0.02)

    static let cpuFrequencyPalette: [Color] = [
        board, package, cpu,
        Color(red: 0.18, green: 0.60, blue: 0.84),
        Color(red: 0.10, green: 0.42, blue: 0.70),
    ]

    static let gpuFrequencyPalette: [Color] = [
        gpu, ane,
        Color(red: 0.92, green: 0.36, blue: 0.18),
        Color(red: 0.86, green: 0.14, blue: 0.34),
    ]
}

@MainActor
private enum MetricsChartDefinitions {
    private enum Formatters {
        static func watts(_ value: Double) -> String {
            String(format: "%.2f", locale: FormatLocale.posix, value)
        }

        static func frequencyGHz(_ value: Double) -> String {
            String(format: "%.2f", locale: FormatLocale.posix, value)
        }

        static func usage(_ value: Double) -> String {
            String(format: "%.1f%%", locale: FormatLocale.posix, value * 100.0)
        }

        static func temperature(_ value: Double) -> String {
            String(format: "%.1f ", locale: FormatLocale.posix, value)
        }
    }

    static let power = MetricsChartDefinition(
        title: "Power",
        unitLabel: "WATT",
        helpMarkdown:
"""
**Power draw by components**

• `SYS` is the total system power draw.
• `CHIP` is the power reported for the whole SoC, including all compute units and memory.
• `CPU`, `GPU`, and `ANE` are individual parts of `CHIP`.
""",
        schemaBuilder: { _ in "power" },
        seriesBuilder: { _ in
            [
                MetricsSeriesDescriptor(
                    title: "SYS",
                    color: MetricsChartPalette.board,
                    kind: .line,
                    chartValue: { Double($0.power.board) },
                    detailsFormatter: Formatters.watts
                ),
                MetricsSeriesDescriptor(
                    title: "CHIP",
                    color: MetricsChartPalette.package,
                    kind: .line,
                    chartValue: { Double($0.power.package) },
                    detailsFormatter: Formatters.watts
                ),
                MetricsSeriesDescriptor(
                    title: "CPU",
                    color: MetricsChartPalette.cpu,
                    kind: .line,
                    chartValue: { Double($0.power.cpu) },
                    detailsFormatter: Formatters.watts
                ),
                MetricsSeriesDescriptor(
                    title: "ANE",
                    color: MetricsChartPalette.ane,
                    kind: .line,
                    chartValue: { Double($0.power.ane) },
                    detailsFormatter: Formatters.watts
                ),
                MetricsSeriesDescriptor(
                    title: "GPU",
                    color: MetricsChartPalette.gpu,
                    kind: .line,
                    chartValue: { Double($0.power.gpu) },
                    detailsFormatter: Formatters.watts
                ),
            ]
        }
    )

    static let temperature = MetricsChartDefinition(
        title: "Temperature",
        unitLabel: "°C",
        helpMarkdown: nil,
        schemaBuilder: { _ in "temperature" },
        seriesBuilder: { _ in
            [
                MetricsSeriesDescriptor(
                    title: "CPU",
                    color: MetricsChartPalette.cpu,
                    kind: .line,
                    lineWidth: 2.0,
                    chartValue: { Double($0.temperature.cpuAverage) },
                    detailsFormatter: Formatters.temperature
                ),
                MetricsSeriesDescriptor(
                    title: "GPU",
                    color: MetricsChartPalette.gpu,
                    kind: .line,
                    lineWidth: 2.0,
                    chartValue: { Double($0.temperature.gpuAverage) },
                    detailsFormatter: Formatters.temperature
                ),
            ]
        }
    )

    static let frequency = MetricsChartDefinition(
        title: "Frequency, usage",
        unitLabel: "GHz",
        helpMarkdown:
"""
Current frequency and usage of all CPU and GPU clusters.

**How to read this mess**
Each cluster is shown with a solid line for frequency \
and a semi-transparent area underneath for current usage. \
The area shows the fraction of that frequency that is being used. \
When usage is at 100%, the area reaches the line.
""",
        schemaBuilder: { metrics in
            guard let metrics else { return AnyHashable("frequency.empty") }
            return AnyHashable(
                metrics.cpu_usage.map(\.name) + ["|"] + metrics.gpu_usage.map(\.name)
            )
        },
        seriesBuilder: { metrics in
            guard let metrics else { return [] }
            return cpuFrequencySeries(from: metrics) + gpuFrequencySeries(from: metrics)
        }
    )

    private static func cpuFrequencySeries(from metrics: Metrics) -> [MetricsSeriesDescriptor] {
        metrics.cpu_usage.enumerated().flatMap { index, cluster in
            let title = metrics.cpu_usage.count == 1 ? "CPU" : cluster.name
            let color = MetricsChartPalette.cpuFrequencyPalette[
                index % MetricsChartPalette.cpuFrequencyPalette.count
            ]
            let group = "cpu.\(index)"

            return [
                MetricsSeriesDescriptor(
                    title: title,
                    color: color,
                    kind: .line,
                    chartValue: { metrics in
                        Double(metrics.cpu_usage[index].frequencyMHz) / 1000
                    },
                    detailsFormatter: Formatters.frequencyGHz,
                    detailsGroup: group
                ),
                MetricsSeriesDescriptor(
                    title: title,
                    color: color.opacity(0.3),
                    kind: .fill,
                    chartValue: { metrics in
                        Double(metrics.cpu_usage[index].usage)
                            * Double(metrics.cpu_usage[index].frequencyMHz) / 1000
                    },
                    detailsValue: { metrics in
                        Double(metrics.cpu_usage[index].usage)
                    },
                    detailsFormatter: Formatters.usage,
                    detailsGroup: group
                ),
            ]
        }
    }

    private static func gpuFrequencySeries(from metrics: Metrics) -> [MetricsSeriesDescriptor] {
        metrics.gpu_usage.enumerated().flatMap { index, cluster in
            let title = metrics.gpu_usage.count == 1 ? "GPU" : cluster.name
            let color = MetricsChartPalette.gpuFrequencyPalette[
                index % MetricsChartPalette.gpuFrequencyPalette.count
            ]
            let group = "gpu.\(index)"

            return [
                MetricsSeriesDescriptor(
                    title: title,
                    color: color,
                    kind: .line,
                    chartValue: { metrics in
                        Double(metrics.gpu_usage[index].frequencyMHz) / 1000
                    },
                    detailsFormatter: Formatters.frequencyGHz,
                    detailsGroup: group
                ),
                MetricsSeriesDescriptor(
                    title: title,
                    color: color.opacity(0.3),
                    kind: .fill,
                    chartValue: { metrics in
                        Double(metrics.gpu_usage[index].usage)
                            * Double(metrics.gpu_usage[index].frequencyMHz) / 1000
                    },
                    detailsValue: { metrics in
                        Double(metrics.gpu_usage[index].usage)
                    },
                    detailsFormatter: Formatters.usage,
                    detailsGroup: group
                ),
            ]
        }
    }
}

// MARK: - SwiftUI content for the popover/window
struct ContentView: View {
    @ObservedObject private var dependencies = AppDependencies.shared
    @ObservedObject var presentationState: MenuPresentationState
    @State private var lastBatteryStatus: String = ""
    @State private var highlightedChartSampleX: Double?

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(dependencies.chipName ?? AppPresentation.pinnedWindowTitle)
                    .font(.headline)
                Text(dependencies.socSummary)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle(
                    isOn: Binding(
                        get: { presentationState.mode == .pinned },
                        set: { isPinned in
                            presentationState.setPresentationMode(isPinned ? .pinned : .attached)
                        }
                    )
                ) {
                    Image(systemName: "pin")
                }
                    .toggleStyle(.button)
                    .help(presentationState.mode == .pinned ? "Attach to menu bar" : "Keep window open")
                Button("⏼") { NSApp.terminate(nil) }
            }
            .padding(.bottom, 4)

            Divider()
                .background(Color(nsColor: .textColor))

            let graphPadding: CGFloat = 8
            let backgroundColor = Color(.textBackgroundColor)
                .padding(.horizontal, -12)
                .padding(.top, -graphPadding)
                .padding(.bottom, -graphPadding + 4)
            GeometryReader { metrics in
                VStack(spacing: graphPadding * 2 - 2) {
                    MetricsChartSection(
                        definition: MetricsChartDefinitions.power,
                        metricsPublisher: dependencies.metricsPublisher,
                        capacity: AppPresentation.chartHistoryCapacity,
                        showUpdates: presentationState.isWindowVisible,
                        highlightedSampleX: $highlightedChartSampleX
                    )
                        .frame(height: metrics.size.height * 0.35)
                        .background(backgroundColor)

                    MetricsChartSection(
                        definition: MetricsChartDefinitions.frequency,
                        metricsPublisher: dependencies.metricsPublisher,
                        capacity: AppPresentation.chartHistoryCapacity,
                        showUpdates: presentationState.isWindowVisible,
                        highlightedSampleX: $highlightedChartSampleX
                    )
                        .frame(height: metrics.size.height * 0.35)
                        .background(backgroundColor)

                    MetricsChartSection(
                        definition: MetricsChartDefinitions.temperature,
                        metricsPublisher: dependencies.metricsPublisher,
                        capacity: AppPresentation.chartHistoryCapacity,
                        showUpdates: presentationState.isWindowVisible,
                        highlightedSampleX: $highlightedChartSampleX,
                        yAxisLabelCount: 4,
                        yStart: 30
                    )
                        .background(backgroundColor)
                }
                    .padding(.bottom, -4)
            }

            if !dependencies.metricsError.isEmpty {
                Text(dependencies.metricsError)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Divider()

            HStack(spacing: 4) {
                Text("Interval:")
                Text(intervalLabel)
                Button("–") {
                    dependencies.decreaseMetricsInterval()
                }
                    .buttonStyle(.plain)
                    .keyboardShortcut("-", modifiers: [])
                Text("/")
                    .foregroundStyle(.secondary)
                Button("+") {
                    dependencies.increaseMetricsInterval()
                }
                    .buttonStyle(.plain)
                    .keyboardShortcut("=", modifiers: [])
                Spacer()
            }

            if !lastBatteryStatus.isEmpty {
                Divider()
                Text(lastBatteryStatus)
                    .textSelection(.enabled)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            DispatchQueue.global(qos: .utility).async {
                if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
                    let exe = exeDir.appendingPathComponent("battery_tracker").path
                    let status = run_once(exe, ["status"]) ?? "(no output)"
                    DispatchQueue.main.async {
                        self.lastBatteryStatus = status.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
        }
    }

    private var intervalLabel: String {
        let interval = dependencies.metricsIntervalMs
        if interval < 1_000 {
            return "\(interval) ms"
        }
        return String(format: "%.2f s", locale: FormatLocale.posix, Double(interval) / 1000.0)
    }
}

@MainActor
private struct StatusItemDisplayDescriptor {
    let displayName: String
    let persistenceValue: String
    let getValue: (Metrics) -> Double?
    let formatValue: (Double) -> String
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var presentationController: MenuPresentationController<ContentView>?
    private var statusMetricsSubscription: AnyCancellable?
    private let statusItemMenu = NSMenu()
    private var lastMetrics: Metrics?
    private var statusItemDisplayDescriptors: [StatusItemDisplayDescriptor] = []
    private var selectedStatusItemDisplayPersistenceValue = AppSettings.statusItemDisplayMode ?? "icon"
    private var statusItemFont = NSFont(name: "Menlo bold", size: 12) ??
        .monospacedSystemFont(ofSize: 13, weight: .bold)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApplication), keyEquivalent: "")
        quitItem.target = self
        statusItemMenu.addItem(quitItem)

        presentationController = MenuPresentationController(
            content: { presentationState in
                ContentView(presentationState: presentationState)
            },
            statusItemMenu: statusItemMenu,
            configureStatusItem: { statusItem in
                guard let button = statusItem.button else { return }
                button.image = nil
                button.toolTip = AppPresentation.statusItemToolTip
                self.applyStatusItemDisplay(metrics: nil, to: statusItem)
            },
            configureWindow: { window in
                window.title = AppPresentation.pinnedWindowTitle
                window.setContentSize(AppPresentation.windowMinSize)
                window.minSize = AppPresentation.windowMinSize
            }
        )

        statusMetricsSubscription = AppDependencies.shared.metricsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] metrics in
                self?.updateStatusItem(with: metrics)
            }
    }

    private func updateStatusItem(with metrics: Metrics) {
        guard let statusItem = presentationController?.statusItem else { return }
        lastMetrics = metrics
        if statusItemDisplayDescriptors.isEmpty {
            buildStatusItemMenu(with: metrics)
        }
        selectedStatusItemDisplayPersistenceValue = sanitizedPersistenceValue(selectedStatusItemDisplayPersistenceValue)
        AppSettings.statusItemDisplayMode = selectedStatusItemDisplayPersistenceValue
        updateStatusItemMenuSelection()
        applyStatusItemDisplay(metrics: metrics, to: statusItem)
    }

    private func formatStatusItemPower(_ value: Double) -> String {
        String(format: "%4.1f W", locale: FormatLocale.posix, value)
    }

    private func formatStatusItemTemperature(_ value: Double) -> String {
        String(format: "%4.1f C", locale: FormatLocale.posix, value)
    }

    private func formatStatusItemUsage(_ value: Double) -> String {
        String(format: "%4.1f%%", locale: FormatLocale.posix, value * 100.0)
    }

    private func formatStatusItemFrequency(_ valueGHz: Double) -> String {
        String(format: "%4.2f GHz", locale: FormatLocale.posix, valueGHz)
    }

    private func applyStatusItemTitle(_ title: String, to statusItem: NSStatusItem) {
        let attributedTitle = NSAttributedString(string: title, attributes: [.font: statusItemFont])
        statusItem.button?.image = nil
        statusItem.button?.attributedTitle = attributedTitle
        statusItem.length = ceil(attributedTitle.size().width)
    }

    private func buildStatusItemMenu(with metrics: Metrics) {
        statusItemDisplayDescriptors = makeStatusItemDisplayDescriptors(metrics: metrics)
        statusItemMenu.insertItem(.separator(), at: 0)
        for descriptor in statusItemDisplayDescriptors.reversed() {
            let item = NSMenuItem(
                title: descriptor.displayName,
                action: #selector(selectStatusItemDisplayMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = descriptor.persistenceValue
            statusItemMenu.insertItem(item, at: 0)
        }
        updateStatusItemMenuSelection()
    }

    private func applyStatusItemDisplay(metrics: Metrics?, to statusItem: NSStatusItem) {
        guard
            let metrics,
            let descriptor = selectedStatusItemDisplayDescriptor,
            let value = descriptor.getValue(metrics)
        else {
            applyStatusItemIcon(to: statusItem)
            return
        }

        applyStatusItemTitle(descriptor.formatValue(value), to: statusItem)
    }

    private func applyStatusItemIcon(to statusItem: NSStatusItem) {
        let image = NSImage(systemSymbolName: AppPresentation.statusItemSystemImageName, accessibilityDescription: AppPresentation.statusItemToolTip)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.attributedTitle = NSAttributedString(string: "")
        statusItem.length = NSStatusItem.variableLength
    }

    private func sanitizedPersistenceValue(_ persistenceValue: String) -> String {
        statusItemDisplayDescriptors.contains { $0.persistenceValue == persistenceValue } ? persistenceValue : "icon"
    }

    private func updateStatusItemMenuSelection() {
        for item in statusItemMenu.items {
            guard let persistenceValue = item.representedObject as? String else { continue }
            item.state = persistenceValue == selectedStatusItemDisplayPersistenceValue ? .on : .off
        }
    }

    @objc private func selectStatusItemDisplayMode(_ sender: NSMenuItem) {
        guard let persistenceValue = sender.representedObject as? String else { return }

        selectedStatusItemDisplayPersistenceValue = sanitizedPersistenceValue(persistenceValue)
        AppSettings.statusItemDisplayMode = selectedStatusItemDisplayPersistenceValue
        updateStatusItemMenuSelection()

        guard let statusItem = presentationController?.statusItem else { return }
        applyStatusItemDisplay(metrics: lastMetrics, to: statusItem)
    }

    private var selectedStatusItemDisplayDescriptor: StatusItemDisplayDescriptor? {
        statusItemDisplayDescriptors.first { $0.persistenceValue == selectedStatusItemDisplayPersistenceValue }
    }

    private func makeStatusItemDisplayDescriptors(metrics: Metrics) -> [StatusItemDisplayDescriptor] {
        var descriptors = [
            StatusItemDisplayDescriptor(
                displayName: "Icon",
                persistenceValue: "icon",
                getValue: { _ in nil },
                formatValue: { _ in "" }
            ),
            StatusItemDisplayDescriptor(
                displayName: "System power",
                persistenceValue: "systemPower",
                getValue: { metrics in Double(metrics.power.board) },
                formatValue: formatStatusItemPower
            ),
            StatusItemDisplayDescriptor(
                displayName: "Chip power",
                persistenceValue: "chipPower",
                getValue: { metrics in Double(metrics.power.package) },
                formatValue: formatStatusItemPower
            ),
            StatusItemDisplayDescriptor(
                displayName: "Temperature",
                persistenceValue: "maxTemperature",
                getValue: { metrics in Double(max(metrics.temperature.cpuAverage, metrics.temperature.gpuAverage)) },
                formatValue: formatStatusItemTemperature
            ),
            StatusItemDisplayDescriptor(
                displayName: "CPU load",
                persistenceValue: "totalCpuLoad",
                getValue: { metrics in
                    let totalUnits = metrics.cpu_usage.reduce(0) { $0 + Int($1.units) }
                    let weightedUsage = metrics.cpu_usage.reduce(0 as Float) { $0 + ($1.usage * Float($1.units)) }
                    return totalUnits > 0 ? Double(weightedUsage / Float(totalUnits)) : 0
                },
                formatValue: formatStatusItemUsage
            ),
        ]

        descriptors += metrics.cpu_usage.enumerated().flatMap { index, cluster in
            [
                StatusItemDisplayDescriptor(
                    displayName: "\(cluster.name) load",
                    persistenceValue: "cpuClusterLoad:\(index)",
                    getValue: { metrics in
                        guard metrics.cpu_usage.indices.contains(index) else { return nil }
                        return Double(metrics.cpu_usage[index].usage)
                    },
                    formatValue: formatStatusItemUsage
                ),
                StatusItemDisplayDescriptor(
                    displayName: "\(cluster.name) frequency",
                    persistenceValue: "cpuClusterFrequency:\(index)",
                    getValue: { metrics in
                        guard metrics.cpu_usage.indices.contains(index) else { return nil }
                        return Double(metrics.cpu_usage[index].frequencyMHz) / 1000.0
                    },
                    formatValue: formatStatusItemFrequency
                ),
            ]
        }

        return descriptors
    }
    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }
}

@main
struct MainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
