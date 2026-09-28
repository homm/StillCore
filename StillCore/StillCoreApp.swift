import AppKit
import Combine
import SwiftUI
import ServiceManagement
import MacmonSwift
import Sparkle

enum AppSettings {
    static let defaultMetricsIntervalMs = 2000
    private static let metricsIntervalKey = "metricsIntervalMs"
    private static let frequencyUsageByCoresKey = "frequencyUsageByCores"
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

    static var frequencyUsageByCores: Bool {
        get {
            UserDefaults.standard.bool(forKey: frequencyUsageByCoresKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: frequencyUsageByCoresKey)
        }
    }
}

enum AppPresentation {
    static let windowMinSize = CGSize(width: 420, height: 560)
    static let statusItemSystemImageName = "chart.bar.xaxis"
    static let statusItemToolTip = "StillCore"
    static let floatingWindowTitle = "StillCore"
    static let chartHistoryCapacity = 200
}

enum FormatLocale {
    static let posix = Locale(identifier: "en_US_POSIX")
}

enum AppFonts {
    static func tabularSystemFont(
        ofSize fontSize: CGFloat,
        weight: NSFont.Weight,
        width: NSFont.Width = NSFont.Width(-0.1)
    ) -> NSFont {
        let baseFont = NSFont.systemFont(ofSize: fontSize, weight: weight, width: width)
        let featureSettings: [[NSFontDescriptor.FeatureKey: Int]] = [
            [
                .typeIdentifier: kNumberSpacingType,
                .selectorIdentifier: kMonospacedNumbersSelector,
            ],
        ]
        let descriptor = baseFont.fontDescriptor.addingAttributes([
            .featureSettings: featureSettings,
        ])

        return NSFont(descriptor: descriptor, size: fontSize) ?? baseFont
    }
    nonisolated(unsafe) static let statusItemButton = tabularSystemFont(
        ofSize: 12, weight: .semibold)
    nonisolated(unsafe) static let intervalMenuLabel = tabularSystemFont(
        ofSize: NSFont.systemFontSize, weight: .regular)
    nonisolated(unsafe) static let batteryPercent = tabularSystemFont(
        ofSize: 12, weight: .medium)
    static let helpIcon = Font.system(size: 13, weight: .semibold)
    static let systemMessage = Font.system(size: 12, design: .monospaced)

    nonisolated(unsafe) static let chartDetailsValue = tabularSystemFont(
        ofSize: 12, weight: .bold)
    nonisolated(unsafe) static let chartDetailsMarkerValue = tabularSystemFont(
        ofSize: 10, weight: .bold)
    nonisolated(unsafe) static let chartLegend = tabularSystemFont(
        ofSize: 12, weight: .medium)
}

// MARK: - DI

@MainActor
final class AppDependencies: ObservableObject {
    static let shared = AppDependencies()

    @Published var chipName: String?
    @Published var socSummary: String = ""
    @Published var metricsError: String = ""
    private(set) var socInfo: SocInfo?
    private var metricsTask: Task<Void, Never>?
    private var lastCPUPower: Float?
    private let metricsSubject = PassthroughSubject<Metrics, Never>()
    @Published private(set) var chartHistoryResetRevision = 0

    func clearChartHistory() {
        chartHistoryResetRevision += 1
    }

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
        lastCPUPower = nil

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
                        AppDependencies.shared.publish(metrics)
                    }
                }
            } catch {
                await MainActor.run {
                    AppDependencies.shared.metricsError = String(describing: error)
                    AppDependencies.shared.metricsTask = nil
                }
            }
        }
    }

    private func publish(_ source: Metrics) {
        var metrics = source
        // A chip spike after zero CPU can include stale energy; retain GPU power only.
        if metrics.power.package > metrics.power.board && (lastCPUPower == nil || lastCPUPower == 0) {
            metrics.power.package = metrics.power.gpu
            metrics.power.cpu = 0
            metrics.power.ane = 0
        }
        lastCPUPower = metrics.power.cpu
        metricsSubject.send(metrics)
        if !metricsError.isEmpty {
            metricsError = ""
        }
    }

    private func loadSocInfo() {
        do {
            let info = try Macmon.socInfo()
            socInfo = info
            chipName = info.chipName
            socSummary = formatSocSummary(info)
        } catch {
            socInfo = nil
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

    @Published var frequencyUsageByCores: Bool = AppSettings.frequencyUsageByCores {
        didSet {
            AppSettings.frequencyUsageByCores = frequencyUsageByCores
        }
    }

    func increaseMetricsInterval() {
        let current = metricsIntervalMs
        let step = Self.intervalStep(for: current)
        metricsIntervalMs = min(
            ((metricsIntervalMs + step) / step) * step, Self.maxMetricsIntervalMs)
    }

    func decreaseMetricsInterval() {
        let step = Self.intervalStep(for: metricsIntervalMs - 1)
        metricsIntervalMs = max(
            (max(metricsIntervalMs - step, 0) + step - 1) / step * step, Self.minMetricsIntervalMs)
    }

    private static func intervalStep(for intervalMs: Int) -> Int {
        if intervalMs >= largeIntervalThresholdMs {
            return largeIntervalStepMs
        }
        if intervalMs >= mediumIntervalThresholdMs {
            return mediumIntervalStepMs
        }
        return intervalStepMs
    }

    private static let minMetricsIntervalMs = 100
    private static let maxMetricsIntervalMs = 10_000
    private static let intervalStepMs = 250
    private static let mediumIntervalStepMs = 500
    private static let mediumIntervalThresholdMs = 1_000
    private static let largeIntervalStepMs = 1_000
    private static let largeIntervalThresholdMs = 3_000
}

private enum MetricsChartPalette {
    static let board = color(light: (0.06, 0.736, 0.14), dark: (0.18, 0.92, 0.28))
    static let package = color(light: (0.058, 0.406, 0.892), dark: (0.13, 0.48, 0.97))
    static let cpu = color(light: (0.246, 0.663, 0.902), dark: (0.32, 0.74, 0.98))
    static let gpu = color(light: (0.92, 0.188, 0.0), dark: (1.0, 0.30, 0.10))
    static let ane = color(light: (0.94, 0.62, 0.0), dark: (1.0, 0.66, 0.08))

    static let cpuFrequencyPalette: [NSColor] = [
        board, package, cpu,
        color(light: (0.117, 0.534, 0.773), dark: (0.26, 0.68, 0.92)),
        color(light: (0.048, 0.366, 0.644), dark: (0.18, 0.52, 0.82)),
    ]

    static let gpuFrequencyPalette: [NSColor] = [
        gpu, ane,
        color(light: (0.846, 0.29, 0.111), dark: (1.0, 0.44, 0.24)),
        color(light: (0.791, 0.076, 0.275), dark: (0.98, 0.22, 0.44)),
    ]

    private static func color(
        light: (red: CGFloat, green: CGFloat, blue: CGFloat),
        dark: (red: CGFloat, green: CGFloat, blue: CGFloat)
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            let components = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: components.red,
                green: components.green,
                blue: components.blue,
                alpha: 1
            )
        }
    }
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
            String(format: "%.1f", locale: FormatLocale.posix, value)
        }
    }

    static let power = MetricsChartDefinition(
        title: "Power",
        unitLabel: "Watt",
        helpMarkdown:
"""
**Power draw by components**

• `SYS` is the total system power draw.
• `CHIP` is the power reported for the whole SoC, including all compute units and memory.
• `CPU`, `GPU`, and `ANE` are individual parts of `CHIP`.
""",
        showsSampleTime: true,
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
        unitLabel: "GHz, %",
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
            let coreCount = cpuChartCoreCount(index: index)

            return [
                MetricsSeriesDescriptor(
                    title: title,
                    color: color,
                    kind: .line,
                    chartValue: { metrics in
                        Double(cpuChartFrequencyMHz(metrics, index: index)) / 1000
                    },
                    detailsFormatter: Formatters.frequencyGHz,
                    detailsGroup: group
                ),
                MetricsSeriesDescriptor(
                    title: title,
                    color: color.withAlphaComponent(0.3),
                    kind: .fill,
                    chartValue: { metrics in
                        Double(metrics.cpu_usage[index].usage)
                            * Double(cpuChartFrequencyMHz(metrics, index: index)) / 1000
                    },
                    detailsValue: { metrics in
                        Double(metrics.cpu_usage[index].usage)
                    },
                    detailsFormatter: { usage in
                        Formatters.usage(
                            usage * (AppDependencies.shared.frequencyUsageByCores ? coreCount : 1)
                        )
                    },
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
                        Double(gpuChartFrequencyMHz(metrics, index: index)) / 1000
                    },
                    detailsFormatter: Formatters.frequencyGHz,
                    detailsGroup: group
                ),
                MetricsSeriesDescriptor(
                    title: title,
                    color: color.withAlphaComponent(0.3),
                    kind: .fill,
                    chartValue: { metrics in
                        Double(metrics.gpu_usage[index].usage)
                            * Double(gpuChartFrequencyMHz(metrics, index: index)) / 1000
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

    private static func cpuChartFrequencyMHz(_ metrics: Metrics, index: Int) -> UInt32 {
        let frequency = metrics.cpu_usage[index].frequencyMHz
        guard frequency == 0,
            let domains = AppDependencies.shared.socInfo?.cpuDomains,
            domains.indices.contains(index),
            let minimumFrequency = domains[index].frequenciesMHz.first
        else { return frequency }
        return minimumFrequency
    }

    private static func cpuChartCoreCount(index: Int) -> Double {
        guard let domains = AppDependencies.shared.socInfo?.cpuDomains,
            domains.indices.contains(index)
        else { return 1 }
        return Double(domains[index].units)
    }

    private static func gpuChartFrequencyMHz(_ metrics: Metrics, index: Int) -> UInt32 {
        let frequency = metrics.gpu_usage[index].frequencyMHz
        guard frequency == 0,
            let minimumFrequency = AppDependencies.shared.socInfo?.gpuFrequenciesMHz.first
        else { return frequency }
        return minimumFrequency
    }
}

// MARK: - SwiftUI content for the popover/window
struct ContentView: View {
    @ObservedObject private var dependencies = AppDependencies.shared
    @ObservedObject private var batteryTrackerService = BatteryTrackerService.shared
    @ObservedObject private var powerMetricsService = PowerMetricsService.shared
    @ObservedObject var presentationState: MenuPresentationState
    @State private var highlightedChartSampleX: Double?
    @State private var isBatteryTrackerPopoverPresented = false
    @State private var isPowerMetricsPopoverPresented = false
    @State private var batteryEnergyModeMenuController = BatteryEnergyModeMenuController()

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(dependencies.chipName ?? AppPresentation.floatingWindowTitle)
                    .font(.headline)
                Text(dependencies.socSummary)
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Text("Update interval:")
                    ForEach(Self.intervalMenuOptions, id: \.milliseconds) { option in
                        Button(option.title) {
                            dependencies.metricsIntervalMs = option.milliseconds
                        }
                    }
                    Divider()
                    Text("Keyboard shortcuts:")
                    Button("More often") {
                        dependencies.decreaseMetricsInterval()
                    }
                        .keyboardShortcut("-", modifiers: [])
                    Button("Less often") {
                        dependencies.increaseMetricsInterval()
                    }
                        .keyboardShortcut("=", modifiers: [])
                    Button("Clear Chart History") {
                        dependencies.clearChartHistory()
                    }
                        .keyboardShortcut("k", modifiers: .command)
                } label: {
                    HStack(spacing: 0) {
                        Image(systemName: "clock.arrow.circlepath")
                        Text(intervalLabel)
                            .font(Font(AppFonts.intervalMenuLabel))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .offset(y: 1)
                            .padding(.leading, 2)
                    }
                }
                    .buttonStyle(AccessoryLikeButtonStyle())
                    .help("Update interval")
                    .padding(.leading, -5)
                    .padding(.trailing, -1)
                    .padding(.vertical, -3)
                Button {
                    presentationState.setPresentationMode(
                        presentationState.mode == .attached ? .floating : .attached)
                } label: {
                    Image(presentationState.mode == .attached ? "PinFloating" : "PinAttached")
                        .resizable().frame(height: 15)
                        .fixedSize().frame(width: 15, height: 15)
                        .offset(y: -1)
                }
                    .help(presentationState.mode == .floating ? "Attach to menu bar" : "Detach from menu bar")
                Button { NSApp.terminate(nil) } label: {
                    Image(systemName: "power")
                }
            }

            if !dependencies.metricsError.isEmpty {
                Text("Macmon error: \(dependencies.metricsError)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .font(AppFonts.systemMessage)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                let backgroundColor = Color(.textBackgroundColor)
                    .padding(EdgeInsets(top: -8, leading: -12, bottom: -4, trailing: -12))
                let chartSectionInsets = EdgeInsets(top: 8, leading: 0, bottom: 4, trailing: 0)
                GeometryReader { metrics in
                    VStack(spacing: 0) {
                        MetricsChartSection(
                            definition: MetricsChartDefinitions.power,
                            metricsPublisher: dependencies.metricsPublisher,
                            capacity: AppPresentation.chartHistoryCapacity,
                            showUpdates: presentationState.isWindowVisible,
                            historyResetRevision: dependencies.chartHistoryResetRevision,
                            highlightedSampleX: $highlightedChartSampleX
                        )
                            .frame(height: metrics.size.height * 0.35)
                            .background(backgroundColor)
                            .overlay(alignment: .topTrailing) {
                                if powerMetricsService.status != .running {
                                    Button {
                                        isPowerMetricsPopoverPresented.toggle()
                                    } label: {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .font(.system(size: 18))
                                            .foregroundStyle(.orange)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("CPU Power Updates")
                                    .popover(isPresented: $isPowerMetricsPopoverPresented, arrowEdge: .top) {
                                        PowerMetricsPopover(service: powerMetricsService)
                                    }
                                    .offset(y: -4)
                                }
                            }
                            .padding(chartSectionInsets)

                        MetricsChartSection(
                            definition: MetricsChartDefinitions.frequency,
                            metricsPublisher: dependencies.metricsPublisher,
                            capacity: AppPresentation.chartHistoryCapacity,
                            showUpdates: presentationState.isWindowVisible,
                            historyResetRevision: dependencies.chartHistoryResetRevision,
                            highlightedSampleX: $highlightedChartSampleX,
                            settingsInvalidationKey: AnyHashable(dependencies.frequencyUsageByCores),
                            settingsView: AnyView(
                                Toggle(
                                    "CPU usage by cores",
                                    isOn: $dependencies.frequencyUsageByCores
                                )
                                    .padding(12)
                            )
                        )
                            .frame(height: metrics.size.height * 0.35)
                            .background(backgroundColor)
                            .padding(chartSectionInsets)

                        MetricsChartSection(
                            definition: MetricsChartDefinitions.temperature,
                            metricsPublisher: dependencies.metricsPublisher,
                            capacity: AppPresentation.chartHistoryCapacity,
                            showUpdates: presentationState.isWindowVisible,
                            historyResetRevision: dependencies.chartHistoryResetRevision,
                            highlightedSampleX: $highlightedChartSampleX,
                            yAxisLabelCount: 4,
                            yStart: 30
                        )
                            .background(backgroundColor)
                            .padding(chartSectionInsets)
                    }
                }
            }

            if BatteryTrackerService.isBatteryAvailable {
                HStack(spacing: 8) {
                    if let batteryState = batteryTrackerService.runtimeState {
                        Button {
                            batteryEnergyModeMenuController.showMenu()
                        } label: {
                            HStack(spacing: 4) {
                                Image(nsImage: BatteryIndicatorImage.make(
                                    state: batteryState,
                                    usesSecondaryMask: false
                                ))
                                    .padding(.vertical, -1)
                                    .foregroundStyle(.secondary)
                                Text("\(Int(batteryState.currentPercent.rounded()))%")
                                    .foregroundStyle(.secondary)
                                    .font(Font(AppFonts.batteryPercent))
                            }
                        }
                            .buttonStyle(AccessoryLikeButtonStyle())
                            .background {
                                BatteryEnergyModeMenuAnchor(
                                    controller: batteryEnergyModeMenuController,
                                    batteryState: batteryState,
                                    openBatterySettings: {
                                        batteryTrackerService.openBatterySettings()
                                    }
                                )
                            }
                            .help("Energy mode")
                            .padding(.leading, -7)
                            .padding(.trailing, -5)
                            .padding(.vertical, -4)
                    }

                    Text(batteryTrackerService.statusText)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)

                    if batteryTrackerService.status != .running {
                        Button {
                            isBatteryTrackerPopoverPresented.toggle()
                        } label: {
                            Image(systemName: "exclamationmark.circle")
                                .font(AppFonts.helpIcon)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Battery tracker")
                        .popover(isPresented: $isBatteryTrackerPopoverPresented, arrowEdge: .bottom) {
                            BatteryTrackerPopover(service: batteryTrackerService)
                        }
                    }
                    Spacer()
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if !BatteryTrackerService.isBatteryAvailable {
                Color(.textBackgroundColor)
                    .frame(height: 12)
                    .allowsHitTesting(false)
            }
        }
    }

    private struct BatteryTrackerPopover: View {
        @ObservedObject var service: BatteryTrackerService

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("Track Battery Usage")
                    .font(.headline)

                Text("StillCore can run a lightweight background service to track battery drain during each unplugged session, even while the app is closed.")

                if let errorMessage = service.errorMessage {
                    Text(errorMessage)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }

                switch service.status {
                case .stopped:
                    Button("Start Service") { Task { await service.start() } }
                case .requiresApproval:
                    Text(
                        "Approve StillCore in System Settings → General → Login Items & Extensions."
                    ).foregroundStyle(.secondary)
                    Button("Open System Settings") { SMAppService.openSystemSettingsLoginItems() }
                case .starting:
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Starting battery tracker…")
                    }
                case .running:
                    EmptyView()
                }
            }
            .padding(12)
            .frame(width: 340, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private struct PowerMetricsPopover: View {
        @ObservedObject var service: PowerMetricsService

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("CPU Power Updates on macOS 27")
                    .font(.headline)
                Text("On macOS 27, CPU power readings can stop updating for third-party apps. Running Apple's powermetrics tool in the background restores updates.")

                if let errorMessage = service.errorMessage {
                    Text(errorMessage)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }

                switch service.status {
                case .stopped:
                    Text(
                        "Enabling this workaround requires administrator approval in System Settings. It adds a small amount of CPU and energy use, runs at background priority, and stops when StillCore quits."
                    ).foregroundStyle(.secondary)
                    Button("Start Service") { Task { await service.start() } }
                case .requiresApproval:
                    Text(
                        "Approve StillCore in System Settings → General → Login Items & Extensions."
                    ).foregroundStyle(.secondary)
                    Button("Open System Settings") { SMAppService.openSystemSettingsLoginItems() }
                case .starting:
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Starting CPU power updates…")
                    }
                case .running:
                    EmptyView()
                }
            }
            .padding(12)
            .frame(width: 340, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var intervalLabel: AttributedString {
        Self.intervalLabel(for: dependencies.metricsIntervalMs)
    }

    private static func intervalLabel(for interval: Int) -> AttributedString {
        let wholeSeconds = interval >= 1_000 ? "\(interval / 1_000)" : ""
        let milliseconds = interval % 1_000
        let fraction: String
        switch milliseconds {
        case 0:
            fraction = ""
        default:
            let digits =
                milliseconds % 100 == 0 ? milliseconds / 100
                : milliseconds % 10 == 0 ? milliseconds / 10
                : milliseconds
            fraction = ".\(digits)"
        }

        return AttributedString("\u{2009}\(wholeSeconds)\(fraction)s")
    }

    private static let intervalMenuOptions = [
        (milliseconds: 250, title: "0.25\u{2006}seconds"),
        (milliseconds: 500, title: "0.5\u{2006}s"),
        (milliseconds: 1_000, title: "1\u{2006}s"),
        (milliseconds: 2_000, title: "2\u{2006}s"),
        (milliseconds: 5_000, title: "5\u{2006}s"),
    ]
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var presentationController: MenuPresentationController<ContentView>?
    private let statusItemMenu = NSMenu()
    private var statusItemController: StatusItemController?
    private var updaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--helpers-uninstall") {
            Task {
                let services: [(String, SMAppService)] = [
                    ("Battery tracker", .agent(plistName: BatteryTrackerConstants.launchAgentPlistName)),
                    ("CPU power", .daemon(plistName: PowerMetricsConstants.plistName)),
                ]
                var failed = false
                for (name, service) in services {
                    if service.status == .notRegistered || service.status == .notFound { continue }
                    do {
                        try await service.unregister()
                    } catch {
                        fputs("Could not uninstall \(name) helper: \(error)\n", stderr)
                        failed = true
                    }
                }
                exit(failed ? EXIT_FAILURE : EXIT_SUCCESS)
            }
            return
        }

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        _ = BatteryTrackerService.shared
        _ = PowerMetricsService.shared

        let aboutItem = NSMenuItem(title: "About...", action: #selector(showAboutPanel), keyEquivalent: "")
        aboutItem.target = self
        statusItemMenu.addItem(aboutItem)

        let updateItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem.target = self
        statusItemMenu.addItem(updateItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApplication), keyEquivalent: "")
        quitItem.target = self
        statusItemMenu.addItem(quitItem)

        let presentationController = MenuPresentationController(
            content: { presentationState in
                ContentView(presentationState: presentationState)
            },
            statusItemMenu: statusItemMenu,
            configureWindow: { window, presentationMode in
                window.title = AppPresentation.floatingWindowTitle
                window.setContentSize(AppPresentation.windowMinSize)

                switch presentationMode {
                case .attached:
                    window.contentMinSize = AppPresentation.windowMinSize
                case .floating:
                    window.minSize = AppPresentation.windowMinSize
                }
            }
        )

        self.presentationController = presentationController
        statusItemController = StatusItemController(
            statusItem: presentationController.statusItem,
            menu: statusItemMenu
        )
    }

    @objc private func showAboutPanel() {
        NSApp.activate()
        AboutPanel.show()
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        updaterController?.checkForUpdates(sender)
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }
}

@MainActor
private enum AboutPanel {
    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits(),
        ])
    }

    private static func credits() -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let credits = NSMutableAttributedString(try! AttributedString(
            markdown: """
MIT licensed
[Source code](https://github.com/homm/StillCore)

Metrics core by [macmon](https://github.com/vladkens/macmon)

Special thanks to
Alyosha Gusev
""",
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ))
        credits.addAttribute(
            .paragraphStyle,
            value: paragraphStyle,
            range: NSRange(location: 0, length: credits.length)
        )
        return credits
    }
}

@main
struct MainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About StillCore") {
                    AboutPanel.show()
                }
            }
            CommandGroup(replacing: .appSettings) {}
            CommandGroup(after: .toolbar) {
                Divider()
                Button("Clear Chart History") {
                    AppDependencies.shared.clearChartHistory()
                }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Decrease Update Interval") {
                    AppDependencies.shared.decreaseMetricsInterval()
                }
                    .keyboardShortcut("-", modifiers: [])
                Button("Increase Update Interval") {
                    AppDependencies.shared.increaseMetricsInterval()
                }
                    .keyboardShortcut("=", modifiers: [])
            }
        }
    }
}
