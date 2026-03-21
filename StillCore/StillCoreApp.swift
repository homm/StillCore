import AppKit
import Combine
import SwiftUI
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

// MARK: - SwiftUI content for the popover/window
struct ContentView: View {
    @ObservedObject private var dependencies = AppDependencies.shared
    @ObservedObject var presentationState: MenuPresentationState
    @State private var lastBatteryStatus: String = ""

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

            VStack(spacing: 8) {
                let graphPadding: CGFloat = 8
                GeometryReader { metrics in
                    VStack(spacing: graphPadding * 2 + 2) {
                        MetricsChartSection(
                            definition: MetricsChartDefinitions.power,
                            metricsPublisher: dependencies.metricsPublisher,
                            capacity: AppPresentation.chartHistoryCapacity,
                            isVisible: presentationState.isWindowVisible,
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
                            metricsPublisher: dependencies.metricsPublisher,
                            capacity: AppPresentation.chartHistoryCapacity,
                            isVisible: presentationState.isWindowVisible,
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
                            metricsPublisher: dependencies.metricsPublisher,
                            capacity: AppPresentation.chartHistoryCapacity,
                            isVisible: presentationState.isWindowVisible,
                            valueFormatter: formattedTemperature,
                            desiredCount: 4,
                            yStart: 30
                        )
                            .background {
                                Color(.textBackgroundColor)
                                .padding(.horizontal, -12)
                                .padding(.vertical, -graphPadding)
                            }
                    }
                }

                if !dependencies.metricsError.isEmpty {
                    Text(dependencies.metricsError)
                        .font(.system(size: 12, design: .monospaced))
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

    private func formattedWatts(_ value: Double) -> String {
        String(format: "%6.2f", locale: FormatLocale.posix, value)
    }

    private func formattedTemperature(_ value: Double) -> String {
        String(format: "%5.1f ", locale: FormatLocale.posix, value)
    }

    private func formattedFrequencyMHz(_ value: Double) -> String {
        String(format: "%6.2f", locale: FormatLocale.posix, value)
    }

    private func formattedUsage(_ value: Double) -> String {
        String(format: "%5.1f%%", locale: FormatLocale.posix, value * 100.0)
    }

    private var intervalLabel: String {
        let interval = dependencies.metricsIntervalMs
        if interval < 1_000 {
            return "\(interval) ms"
        }
        return String(format: "%.2f s", locale: FormatLocale.posix, Double(interval) / 1000.0)
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
struct MainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
