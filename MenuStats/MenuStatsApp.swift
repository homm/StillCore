import AppKit
import SwiftUI
import Charts
import MacmonSwift

enum AppSettings {
    static let defaultMetricsIntervalMs = 2000
    private static let metricsIntervalKey = "metricsIntervalMs"

    static var metricsIntervalMs: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: metricsIntervalKey)
            return value == 0 ? defaultMetricsIntervalMs : value
        }
        set {
            UserDefaults.standard.set(newValue, forKey: metricsIntervalKey)
        }
    }
}

enum AppPresentation {
    static let windowMinSize = CGSize(width: 420, height: 560)
    static let statusItemSystemImageName = "chart.bar.xaxis"
    static let statusItemFallbackTitle = "MS"
    static let statusItemToolTip = "MenuStats"
    static let pinnedWindowTitle = "MenuStats"
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

private struct MetricsSeriesDescriptor: Identifiable {
    let id: String
    let title: String
    let color: Color
    let value: (Metrics) -> Double
    var usageValue: ((Metrics) -> Double)?
}

private struct MetricsSample: Identifiable {
    let sampleID: Int
    let metrics: Metrics

    var id: Int { sampleID }
}

@MainActor
private struct MetricsChartDefinition {
    let title: String
    let unitLabel: String
    private let seriesBuilder: (Metrics?) -> [MetricsSeriesDescriptor]

    init(title: String, unitLabel: String, series: [MetricsSeriesDescriptor]) {
        self.title = title
        self.unitLabel = unitLabel
        self.seriesBuilder = { _ in series }
    }

    init(
        title: String,
        unitLabel: String,
        seriesBuilder: @escaping (Metrics?) -> [MetricsSeriesDescriptor]
    ) {
        self.title = title
        self.unitLabel = unitLabel
        self.seriesBuilder = seriesBuilder
    }

    func resolvedSeries(from metrics: Metrics?) -> [MetricsSeriesDescriptor] {
        seriesBuilder(metrics)
    }
}

@MainActor
private enum MetricsChartDefinitions {
    static let power = MetricsChartDefinition(
        title: "Power",
        unitLabel: "WATT",
        series: [
            MetricsSeriesDescriptor(
                id: "board",
                title: "BOARD",
                color: MetricsChartPalette.board,
                value: { Double($0.power.board) }
            ),
            MetricsSeriesDescriptor(
                id: "package",
                title: "PKG",
                color: MetricsChartPalette.package,
                value: { Double($0.power.package) }
            ),
            MetricsSeriesDescriptor(
                id: "cpu",
                title: "CPU",
                color: MetricsChartPalette.cpu,
                value: { Double($0.power.cpu) }
            ),
            MetricsSeriesDescriptor(
                id: "ane",
                title: "ANE",
                color: MetricsChartPalette.ane,
                value: { Double($0.power.ane) }
            ),
            MetricsSeriesDescriptor(
                id: "gpu",
                title: "GPU",
                color: MetricsChartPalette.gpu,
                value: { Double($0.power.gpu) }
            ),
        ]
    )

    static let frequency = MetricsChartDefinition(
        title: "Frequency, usage",
        unitLabel: "GHz",
        seriesBuilder: { metrics in
            guard let metrics else { return [] }
            return cpuFrequencySeries(from: metrics) + gpuFrequencySeries(from: metrics)
        }
    )

    static let temperature = MetricsChartDefinition(
        title: "Temperature",
        unitLabel: "°C",
        series: [
            MetricsSeriesDescriptor(
                id: "cpu-average",
                title: "CPU AVG",
                color: MetricsChartPalette.cpu,
                value: { Double($0.temperature.cpuAverage) }
            ),
            MetricsSeriesDescriptor(
                id: "gpu-average",
                title: "GPU AVG",
                color: MetricsChartPalette.gpu,
                value: { Double($0.temperature.gpuAverage) }
            ),
        ]
    )
    private static func cpuFrequencySeries(from metrics: Metrics) -> [MetricsSeriesDescriptor] {
        metrics.cpu.enumerated().map { index, cluster in
            let title = frequencyTitle(
                prefix: "CPU",
                rawName: cluster.name,
                fallbackIndex: index,
                normalizedName: normalizedCPUClusterName
            )

            return MetricsSeriesDescriptor(
                id: "cpu-frequency-\(index)",
                title: title,
                color: MetricsChartPalette.cpuFrequencyPalette[index % MetricsChartPalette.cpuFrequencyPalette.count],
                value: { metrics in
                    guard metrics.cpu.indices.contains(index) else { return 0 }
                    return Double(metrics.cpu[index].frequencyMHz) / 1000
                },
                usageValue: { metrics in
                    guard metrics.cpu.indices.contains(index) else { return 0 }
                    return Double(metrics.cpu[index].usage)
                }
            )
        }
    }

    private static func gpuFrequencySeries(from metrics: Metrics) -> [MetricsSeriesDescriptor] {
        metrics.gpu.enumerated().map { index, cluster in
            let title = frequencyTitle(
                prefix: "GPU",
                rawName: cluster.name,
                fallbackIndex: index,
                normalizedName: normalizedGPUClusterName
            )

            return MetricsSeriesDescriptor(
                id: "gpu-frequency-\(index)",
                title: title,
                color: MetricsChartPalette.gpuFrequencyPalette[index % MetricsChartPalette.gpuFrequencyPalette.count],
                value: { metrics in
                    guard metrics.gpu.indices.contains(index) else { return 0 }
                    return Double(metrics.gpu[index].frequencyMHz) / 1000
                },
                usageValue: { metrics in
                    guard metrics.gpu.indices.contains(index) else { return 0 }
                    return Double(metrics.gpu[index].usage)
                }
            )
        }
    }

    private static func frequencyTitle(
        prefix: String,
        rawName: String,
        fallbackIndex: Int,
        normalizedName: (String) -> String
    ) -> String {
        let normalized = normalizedName(rawName)
        if normalized.isEmpty {
            return "\(prefix) \(fallbackIndex + 1)"
        }
        return "\(prefix) \(normalized)"
    }
}

private func normalizedCPUClusterName(_ rawName: String) -> String {
    let lower = rawName.lowercased()
    if lower == "ecpu" {
        return "E"
    }
    if lower == "pcpu" {
        return "P"
    }
    return rawName.isEmpty ? "" : rawName.uppercased()
}

private func normalizedGPUClusterName(_ rawName: String) -> String {
    rawName.isEmpty ? "" : rawName.uppercased()
}

private extension View {
    @ViewBuilder
    func chartYScaleIfPresent(_ domain: ClosedRange<Double>?) -> some View {
        if let domain {
            self.chartYScale(domain: domain)
        } else {
            self
        }
    }
}


// MARK: - DI

@MainActor
final class AppDependencies: ObservableObject {
    static let shared = AppDependencies()

    @Published var chipName: String?
    @Published var socSummary: String = ""
    @Published var latestMetrics: Metrics?
    @Published var metricsError: String = ""
    fileprivate private(set) var metricsHistory = RingBuffer<MetricsSample>(capacity: 180)
    private var metricsTask: Task<Void, Never>?
    private var latestCollectedMetrics: Metrics?
    private var latestCollectedMetricsError: String = ""
    private var isContentVisible: Bool = false

    private init() {
        startMetricsLoop()
        loadSocInfo()
    }

    func startMetricsLoop() {
        guard metricsTask == nil else { return }
        metricsError = ""

        metricsTask = Task.detached(priority: .background) {
            let clock = ContinuousClock()
            var lastUpdateStarted = clock.now

            do {
                let sampler = try Sampler()
                defer { sampler.close() }

                while !Task.isCancelled {
                    let intervalMs = await MainActor.run { AppDependencies.shared.metricsIntervalMs }
                    let sampleInterval = Swift.Duration.milliseconds(intervalMs)
                    let elapsed = lastUpdateStarted.duration(to: clock.now)

                    if elapsed < sampleInterval {
                        do {
                            try await Task.sleep(for: sampleInterval - elapsed)
                        } catch {
                            break
                        }
                    }

                    guard !Task.isCancelled else { break }
                    lastUpdateStarted = clock.now

                    let metrics = try sampler.metrics()
                    await MainActor.run {
                        let sampleID = AppDependencies.shared.metricsHistory.appendedCount
                        let sample = MetricsSample(sampleID: sampleID, metrics: metrics)
                        AppDependencies.shared.metricsHistory.append(sample)
                        AppDependencies.shared.latestCollectedMetrics = metrics
                        AppDependencies.shared.latestCollectedMetricsError = ""
                        AppDependencies.shared.publishMetricsStateIfVisible()
                    }
                }
            } catch {
                await MainActor.run {
                    AppDependencies.shared.latestCollectedMetrics = nil
                    AppDependencies.shared.latestCollectedMetricsError = "Macmon metrics error: \(error)"
                    AppDependencies.shared.publishMetricsStateIfVisible()
                    AppDependencies.shared.metricsTask = nil
                }
            }
        }
    }


    func setContentVisible(_ isVisible: Bool) {
        guard isContentVisible != isVisible else { return }
        isContentVisible = isVisible

        if isVisible {
            latestMetrics = latestCollectedMetrics
            metricsError = latestCollectedMetricsError
        }
    }

    private func publishMetricsStateIfVisible() {
        guard isContentVisible else { return }
        latestMetrics = latestCollectedMetrics
        metricsError = latestCollectedMetricsError
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
            let name = normalizedCPUClusterName(domain.name)
            guard !name.isEmpty else { return nil }
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

    private static let minMetricsIntervalMs = 1
    private static let maxMetricsIntervalMs = 10_000
    private static let intervalStepMs = 250
    private static let largeIntervalStepMs = 1_000
    private static let largeIntervalThresholdMs = 5_000
}

private struct MetricsChartSection: View {
    let definition: MetricsChartDefinition
    let samples: [MetricsSample]
    let latestMetrics: Metrics?
    let xDomain: ClosedRange<Int>
    let valueFormatter: (Double) -> String
    var usageValueFormatter: ((Double) -> String)? = nil
    var desiredCount = 7
    var lineWidth = 1.0
    var yScaleDomain: ClosedRange<Double>? = nil

    private var resolvedSeries: [MetricsSeriesDescriptor] {
        definition.resolvedSeries(from: latestMetrics ?? samples.last?.metrics)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if samples.isEmpty {
                VStack(alignment: .leading) {
                    Spacer().frame(height: 24)
                    Text("Waiting for metrics...")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                chartView
                if let latestMetrics {
                    latestValuesView(metrics: latestMetrics)
                }
            }
        }
            .padding(.top, 2)
            .overlay(alignment: .topLeading, content: headerView)
    }

    private var chartView: some View {
        Chart {
            ForEach(resolvedSeries) { series in
                if let usageValue = series.usageValue {
                    ForEach(samples, id: \.id) { sample in
                        AreaMark(
                            x: .value("Sample", sample.sampleID),
                            yStart: .value("Usage Base", 0),
                            yEnd: .value("Usage", usageValue(sample.metrics) * series.value(sample.metrics)),
                        )
                            .foregroundStyle(by: .value("Series", series.title))
                            .opacity(0.3)
                            .interpolationMethod(.linear)
                    }
                }
            }

            ForEach(resolvedSeries.reversed()) { series in
                ForEach(samples, id: \.id) { sample in
                    LineMark(
                        x: .value("Sample", sample.sampleID),
                        y: .value("Value", series.value(sample.metrics)),
                    )
                        .foregroundStyle(by: .value("Series", series.title))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: lineWidth))
                }
            }
        }
        .chartForegroundStyleScale(
            domain: resolvedSeries.map(\.title),
            range: resolvedSeries.map(\.color)
        )
        .chartLegend(position: .top, alignment: .trailing, spacing: 10)
        .chartXScale(domain: xDomain)
        .chartYScaleIfPresent(yScaleDomain)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: desiredCount)) { value in
                AxisGridLine(
                    stroke: value.as(Double.self) == 0
                        ? StrokeStyle(lineWidth: 1)
                        : StrokeStyle(lineWidth: 0.5, dash: [3, 2])
                )
                AxisValueLabel()
            }
        }
        .chartXAxis(.hidden)
    }

    private func latestValuesView(metrics: Metrics) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            ForEach(resolvedSeries) { series in
                Text(valueFormatter(series.value(metrics)))
                    .font(.system(.footnote, design: .monospaced))
                    .fontWeight(.bold)
                    .foregroundStyle(series.color)
                if let usageValueFormatter, let usageValue = series.usageValue {
                    Text(usageValueFormatter(usageValue(metrics)))
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func headerView() -> some View {
        HStack(alignment: .bottom) {
            Text(definition.title)
                .font(.headline)
            Spacer()
            Text(definition.unitLabel)
                .font(.system(.callout, design: .monospaced))
                .fontWeight(.bold)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - SwiftUI content for the popover/window
struct ContentView: View {
    @ObservedObject private var dependencies = AppDependencies.shared
    @ObservedObject var presentationState: MenuPresentationState
    @State private var lastBatteryStatus: String = ""

    var body: some View {
        let chartSamples = dependencies.metricsHistory.snapshot()

        VStack(spacing: 8) {
            HStack {
                Text(dependencies.chipName ?? "MenuStats")
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

            VStack(spacing: 8) {
                let graphPadding: CGFloat = 8
                GeometryReader { metrics in
                    VStack(spacing: graphPadding * 2 + 2) {
                        MetricsChartSection(
                            definition: MetricsChartDefinitions.power,
                            samples: chartSamples,
                            latestMetrics: dependencies.latestMetrics,
                            xDomain: chartXDomain,
                            valueFormatter: formattedWatts
                        )
                            .frame(height: metrics.size.height * 0.35)
                            .background {
                                Color(.textBackgroundColor)
                                .padding(.horizontal, -12)
                                .padding(.vertical, -graphPadding)
                            }

                        MetricsChartSection(
                            definition: MetricsChartDefinitions.frequency,
                            samples: chartSamples,
                            latestMetrics: dependencies.latestMetrics,
                            xDomain: chartXDomain,
                            valueFormatter: formattedFrequencyMHz,
                            usageValueFormatter: formattedUsage
                        )
                            .frame(height: metrics.size.height * 0.35)
                            .background {
                                Color(.textBackgroundColor)
                                .padding(.horizontal, -12)
                                .padding(.vertical, -graphPadding)
                            }

                        MetricsChartSection(
                            definition: MetricsChartDefinitions.temperature,
                            samples: chartSamples,
                            latestMetrics: dependencies.latestMetrics,
                            xDomain: chartXDomain,
                            valueFormatter: formattedTemperature,
                            desiredCount: 5,
                            yScaleDomain: 30...110
                        )
                            .background {
                                Color(.textBackgroundColor)
                                .padding(.horizontal, -12)
                                .padding(.vertical, -graphPadding)
                            }
                    }
                }

                if dependencies.latestMetrics == nil && !dependencies.metricsError.isEmpty {
                    Text(dependencies.metricsError)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
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
                    .font(.system(.callout, design: .monospaced))
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
        .onChange(of: presentationState.isWindowVisible, initial: true) { _, isVisible in
            dependencies.setContentVisible(isVisible)
        }
    }

    private func formattedWatts(_ value: Double) -> String {
        String(format: "%6.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private func formattedTemperature(_ value: Double) -> String {
        String(format: "%5.1f ", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private func formattedFrequencyMHz(_ value: Double) -> String {
        String(format: "%6.2f",locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private func formattedUsage(_ value: Double) -> String {
        String(format: "%5.1f%%", locale: Locale(identifier: "en_US_POSIX"), value * 100.0)
    }

    private var intervalLabel: String {
        let interval = dependencies.metricsIntervalMs
        if interval < 1_000 {
            return "\(interval) ms"
        }
        return String(format: "%.2f s", Double(interval) / 1000.0)
    }

    private var chartXDomain: ClosedRange<Int> {
        let buffer = dependencies.metricsHistory
        let lowerBound = buffer.appendedCount - buffer.capacity
        return lowerBound...buffer.appendedCount
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var presentationController: MenuPresentationController<ContentView>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        presentationController = MenuPresentationController(
            content: { presentationState in
                ContentView(presentationState: presentationState)
            },
            configureStatusItem: { statusItem in
                guard let button = statusItem.button else { return }

                if let image = NSImage(
                    systemSymbolName: AppPresentation.statusItemSystemImageName,
                    accessibilityDescription: AppPresentation.statusItemToolTip
                ) {
                    image.isTemplate = true
                    button.image = image
                    button.title = ""
                } else {
                    button.title = AppPresentation.statusItemFallbackTitle
                }

                button.toolTip = AppPresentation.statusItemToolTip
            },
            configureWindow: { window in
                window.title = AppPresentation.pinnedWindowTitle
                window.setContentSize(AppPresentation.windowMinSize)
                window.minSize = AppPresentation.windowMinSize
            }
        )
    }
}

@main
struct MenuStatsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
