import os
import SwiftUI
import MacmonSwift

let log = Logger(subsystem: "com.user.MenuStats", category: "stream")


// MARK: - DI: точка доступа к лог-тексту и процессу

@MainActor
final class AppDependencies: ObservableObject {
    static let shared = AppDependencies()

    @Published var logHeader: AttributedString = ""
    @Published var latestMetrics: Metrics?
    @Published var metricsError: String = ""
    weak var log: LogTextView.Coordinator?
    private var pendingLines: [String] = []
    private var metricsIntervalMs: Int = 2000
    private var metricsTask: Task<Void, Never>?
    let streamer = StreamedProcess()

    var streamArgs: [String] = "--samplers cpu_power --format plist -i".components(separatedBy: " ")

    private init() {
        startMetricsLoopIfNeeded()
    }

    func restartStream(_ interval: Int) {
        guard let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() else { return }
        let exe = exeDir.appendingPathComponent("pgauge").path

        let args = streamArgs + [String(interval)]
        var headerSet = false
        streamer.start(pGaugeCommand: exe, powerMetricsArgs: args) { [weak self] line in
            guard let self else { return }
            DispatchQueue.main.async {
                if !headerSet {
                    headerSet = true
                    self.logHeader = AttributedString(attributedFromANSI(line))
                } else {
                    if let coord = self.log {
                        coord.appendLine(line)
                    } else {
                        self.pendingLines.append(line)
                    }
                }
            }
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

    func attachLog(_ coord: LogTextView.Coordinator) {
        self.log = coord
        pendingLines.forEach { line in
            coord.appendLine(line)
        }
        pendingLines.removeAll()
    }
}


// MARK: - SwiftUI content for the popover/window
struct ContentView: View {
    @ObservedObject private var dependencies = AppDependencies.shared
    @State private var capacity: Int = 1000
    @State private var interval: Int = 2000
    @State private var lastBatteryStatus: String = ""

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Stats tail").font(.headline)
                Text("last")
                Stepper("",
                        value: $capacity,
                        in: 10...10_000,
                        step: 10,
                        onEditingChanged: { _ in
                            dependencies.log?.setCapacity(capacity)
                        })
                    .labelsHidden()
                Text("\(capacity) lines")
                Spacer()
                Button("Close") { NSApp.terminate(nil) }
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

            if !dependencies.logHeader.characters.isEmpty {
                Text(dependencies.logHeader)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, -8)
            }
            LogTextView { coord in
                dependencies.attachLog(coord)
                coord.setCapacity(capacity)
            }

            HStack {
                Text("Interval:")
                Stepper("Interval",
                        value: $interval,
                        in: 100...10_000,
                        step: 100)
                .labelsHidden()
                Text("\(interval) ms")
                Button("Restart") {
                    dependencies.restartStream(interval)
                }
                Spacer()
                Button("Clear") { dependencies.log?.clear() }
            }

            if !lastBatteryStatus.isEmpty {
                Divider()
                Text(sanitizeANSI(lastBatteryStatus))
                    .textSelection(.enabled)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        }
        .padding(12)
        .onAppear {
            dependencies.log?.scrollVerticallyToBottom()
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
}

// MARK: - App entry (MenuBarExtra ensures icon exists)

struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }

            // Разрешаем ресайз
            window.styleMask.insert(.resizable)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

@main
struct MenuStatsApp: App {
    init() {
        AppDependencies.shared.restartStream(2000)
    }

    var body: some Scene {
        MenuBarExtra("MenuStats", systemImage: "chart.bar.xaxis") {
            ContentView()
                .frame(minWidth: 420, minHeight: 600)
                .background(WindowConfigurator())
        }
        .menuBarExtraStyle(.window)
    }
}
