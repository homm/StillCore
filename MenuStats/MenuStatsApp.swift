import SwiftUI
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

    @Published var socSummary: String = ""
    @Published var latestMetrics: Metrics?
    @Published var metricsError: String = ""
    private var metricsIntervalMs: Int = AppSettings.savedMetricsIntervalMs
    private var metricsTask: Task<Void, Never>?

    private init() {
        loadSocInfo()
        startMetricsLoopIfNeeded()
    }

    private func loadSocInfo() {
        do {
            socSummary = formatSocSummary(try Macmon.socInfo())
        } catch {
            socSummary = ""
        }
    }

    func startMetricsLoopIfNeeded() {
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

    private func formatSocSummary(_ info: SocInfo) -> String {
        let cpuParts = info.cpuDomains.compactMap { domain -> String? in
            let name = cpuDomainLabel(for: domain.name)
            guard !name.isEmpty else { return nil }
            return "\(domain.units) \(name)"
        }

        var parts = [info.chipName]
        if !cpuParts.isEmpty {
            parts.append(cpuParts.joined(separator: ", "))
        }
        parts.append("\(info.gpuCores) GPU")
        return parts.joined(separator: " ")
    }

    private func cpuDomainLabel(for rawName: String) -> String {
        let lower = rawName.lowercased()
        if lower.contains("eff") || lower.contains("e-core") || lower == "ecpu" {
            return "ECPU"
        }
        if lower.contains("perf") || lower.contains("p-core") || lower == "pcpu" {
            return "PCPU"
        }
        return rawName.uppercased()
    }
}


// MARK: - SwiftUI content for the popover/window
struct ContentView: View {
    @ObservedObject private var dependencies = AppDependencies.shared
    @AppStorage(AppSettings.metricsIntervalKey)
    private var interval: Int = AppSettings.defaultMetricsIntervalMs
    @State private var lastBatteryStatus: String = ""

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(dependencies.socSummary.isEmpty ? "MenuStats" : dependencies.socSummary)
                    .font(.headline)
                Spacer()
                Button("⏼") { NSApp.terminate(nil) }
            }
            .padding(.bottom, 4)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Power")
                    .font(.headline)

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
        .onChange(of: interval) { newValue in
            dependencies.updateMetricsInterval(newValue)
        }
    }

    @ViewBuilder
    private func powerValue(_ label: String, _ value: Float) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .foregroundStyle(.secondary)
            Text("\(value, specifier: "%.1f") W")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var intervalLabel: String {
        if interval < 1_000 {
            return "\(interval) ms"
        }
        return String(format: "%.2f s", Double(interval) / 1000.0)
    }

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
