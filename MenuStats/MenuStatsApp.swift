import SwiftUI
import Charts
import MacmonSwift

enum AppSettings {
    static let defaultMetricsIntervalMs = 2000
    static let metricsIntervalKey = "metricsIntervalMs"

    static var savedMetricsIntervalMs: Int {
        let value = UserDefaults.standard.integer(forKey: metricsIntervalKey)
        return value == 0 ? defaultMetricsIntervalMs : value
    }
}


// MARK: - DI

@MainActor
final class AppDependencies: ObservableObject {
    static let shared = AppDependencies()

    @Published var chipName: String?
    @Published var socSummary: String = ""
    @Published var latestMetrics: Metrics?
    @Published private(set) var metricsHistory: [Metrics] = []
    @Published var metricsError: String = ""
    fileprivate private(set) var metricsBuffer = MetricsRingBuffer(capacity: 100)
    private var metricsIntervalMs: Int = AppSettings.savedMetricsIntervalMs
    private var metricsTask: Task<Void, Never>?

    private init() {
        startMetricsLoop()
        loadSocInfo()
    }

    func startMetricsLoop() {
        guard metricsTask == nil else { return }
        metricsError = ""

        metricsTask = Task.detached(priority: .utility) {
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
                        AppDependencies.shared.metricsBuffer.append(metrics)
                        AppDependencies.shared.metricsHistory = AppDependencies.shared.metricsBuffer.snapshot()
                        AppDependencies.shared.latestMetrics = metrics
                        AppDependencies.shared.metricsError = ""
                    }
                }
            } catch {
                await MainActor.run {
                    AppDependencies.shared.latestMetrics = nil
                    AppDependencies.shared.metricsError = "Macmon metrics error: \(error)"
                    AppDependencies.shared.metricsTask = nil
                }
            }
        }
    }

    func updateMetricsInterval(_ interval: Int) {
        metricsIntervalMs = interval
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
            let name = cpuDomainLabel(for: domain.name)
            guard !name.isEmpty else { return nil }
            return "\(domain.units) \(name)"
        }
        parts.append("\(info.gpuCores) GPU cores")
        return parts.joined(separator: ", ")
    }

    private func cpuDomainLabel(for rawName: String) -> String {
        let lower = rawName.lowercased()
        if lower == "ecpu" {
            return "E-cores"
        }
        if lower == "pcpu" {
            return "P-cores"
        }
        return rawName;
    }
}


// MARK: - SwiftUI content for the popover/window
struct ContentView: View {
    private enum PowerSeries: String, CaseIterable {
        case package = "PKG"
        case cpu = "CPU"
        case board = "BOARD"
        case ane = "ANE"
        case gpu = "GPU"
    }

    private struct PowerPoint: Identifiable {
        let id: String
        let sample: Int
        let series: PowerSeries
        let watts: Double
    }

    @ObservedObject private var dependencies = AppDependencies.shared
    @AppStorage(AppSettings.metricsIntervalKey)
    private var interval: Int = AppSettings.defaultMetricsIntervalMs
    @State private var lastBatteryStatus: String = ""

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(dependencies.chipName ?? "MenuStats")
                    .font(.headline)
                Text(dependencies.socSummary)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("⏼") { NSApp.terminate(nil) }
            }
            .padding(.bottom, 4)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Power")
                        .font(.headline)
                    Spacer()
                    Text("WATT")
                        .font(.system(.callout, design: .monospaced))
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)

                if !powerHistory.isEmpty {
                    Chart(powerHistory) { point in
                        LineMark(
                            x: .value("Sample", point.sample),
                            y: .value("Watts", point.watts),
                            series: .value("Series", point.series.rawValue)
                        )
                            .foregroundStyle(by: .value("Series", point.series.rawValue))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                        .chartForegroundStyleScale(powerColorScale)
                        .chartXScale(domain: 0...max(dependencies.metricsBuffer.capacity - 1, 0))
                        .chartYAxis{AxisMarks(position: .leading)}
                        .chartXAxis(.hidden)
                }

                if let power = dependencies.latestMetrics?.power {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                        GridRow {
                            powerValue("Package", power.package)
                            powerValue("CPU", power.cpu)
                            powerValue("GPU", power.gpu)
                        }
                        GridRow {
                            powerValue("RAM", power.ram)
                            powerValue("GPU RAM", power.gpuRAM)
                            powerValue("ANE", power.ane)
                        }
                        GridRow {
                            powerValue("Board", power.board)
                            powerValue("Battery", power.battery)
                            powerValue("DC In", power.dcIn)
                        }
                    }
                    .font(.system(.callout, design: .monospaced))
                } else if !dependencies.metricsError.isEmpty {
                    Text(dependencies.metricsError)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    Text("Waiting for metrics...")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("Interval:")
                Button("-") {
                    interval = fasterInterval(from: interval)
                }
                    .buttonStyle(.plain)
                    .keyboardShortcut("-", modifiers: [])
                Text("/")
                    .foregroundStyle(.secondary)
                Button("+") {
                    interval = slowerInterval(from: interval)
                }
                    .buttonStyle(.plain)
                    .keyboardShortcut("=", modifiers: [])
                Text(intervalLabel)
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
        .onAppear {
            dependencies.updateMetricsInterval(interval)
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
        .onChange(of: interval) {
            dependencies.updateMetricsInterval(interval)
        }
    }

    @ViewBuilder
    private func powerValue(_ label: String, _ value: Float) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .foregroundStyle(.secondary)
            Text("\(value.formatted(.number.precision(.fractionLength(0...2)))) W")
        }
    }

    private var intervalLabel: String {
        if interval < 1_000 {
            return "\(interval) ms"
        }
        return String(format: "%.2f s", Double(interval) / 1000.0)
    }

    private var powerHistory: [PowerPoint] {
        dependencies.metricsHistory.enumerated().flatMap { idx, metrics in
            [
                PowerPoint(id: "board-\(idx)", sample: idx, series: .board, watts: Double(metrics.power.board)),
                PowerPoint(id: "pkg-\(idx)", sample: idx, series: .package, watts: Double(metrics.power.package)),
                PowerPoint(id: "cpu-\(idx)", sample: idx, series: .cpu, watts: Double(metrics.power.cpu)),
                PowerPoint(id: "ane-\(idx)", sample: idx, series: .ane, watts: Double(metrics.power.ane)),
                PowerPoint(id: "gpu-\(idx)", sample: idx, series: .gpu, watts: Double(metrics.power.gpu)),
            ]
        }
    }

    private var powerColorScale: KeyValuePairs<String, Color> {
        [
            PowerSeries.board.rawValue: boardColor,
            PowerSeries.package.rawValue: packageColor,
            PowerSeries.cpu.rawValue: cpuColor,
            PowerSeries.ane.rawValue: aneColor,
            PowerSeries.gpu.rawValue: gpuColor,
        ]
    }

    private func color(for series: PowerSeries) -> Color {
        switch series {
        case .package: return packageColor
        case .cpu: return cpuColor
        case .board: return boardColor
        case .ane: return aneColor
        case .gpu: return gpuColor
        }
    }

    private let packageColor = Color(red: 0.13, green: 0.48, blue: 0.97)
    private let cpuColor = Color(red: 0.32, green: 0.74, blue: 0.98)
    private let boardColor = Color(red: 0.12, green: 0.72, blue: 0.40)
    private let aneColor = Color(red: 0.98, green: 0.58, blue: 0.02)
    private let gpuColor = Color(red: 0.98, green: 0.22, blue: 0.44)

    private static let minIntervalMs = 100
    private static let snapStepMs = 250
    private static let largeStepMs = 1_000
    private static let largeThresholdMs = 5_000
    private static let maxIntervalMs = 10_000

    private func slowerInterval(from current: Int) -> Int {
        let step = current >= Self.largeThresholdMs ? Self.largeStepMs : Self.snapStepMs
        return min(((current + step) / step) * step, Self.maxIntervalMs)
    }

    private func fasterInterval(from current: Int) -> Int {
        let step = current > Self.largeThresholdMs ? Self.largeStepMs : Self.snapStepMs
        return max((max(current - step, 0) + step - 1) / step * step, Self.minIntervalMs)
    }
}

struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.styleMask.insert(.resizable)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

@main
struct MenuStatsApp: App {
    var body: some Scene {
        MenuBarExtra("MenuStats", systemImage: "chart.bar.xaxis") {
            ContentView()
                .frame(minWidth: 420, minHeight: 400)
                .background(WindowConfigurator())
        }
        .menuBarExtraStyle(.window)
    }
}
