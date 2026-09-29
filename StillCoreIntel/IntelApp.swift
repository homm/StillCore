import AppKit
import Combine
import SwiftUI
import ServiceManagement

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
    static let windowMinSize = CGSize(width: 420, height: 420)
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
    @Published var chipName: String? = "Intel CPU"
    @Published var socSummary = ""
    @Published private(set) var chartHistoryResetRevision = 0
    @Published var metricsIntervalMs: Int = AppSettings.metricsIntervalMs {
        didSet {
            AppSettings.metricsIntervalMs = metricsIntervalMs
            IntelPowerMetricsService.shared.start(intervalMs: metricsIntervalMs)
        }
    }
    var metricsPublisher: AnyPublisher<Metrics, Never> { IntelPowerMetricsService.shared.publisher }
    private var subscription: AnyCancellable?

    private init() {
        subscription = metricsPublisher.sink { [weak self] metrics in
            self?.socSummary = metrics.cpu_usage.map { "\($0.units)\($0.name) cores" }.joined(separator: " ")
        }
        IntelPowerMetricsService.shared.start(intervalMs: metricsIntervalMs)
    }

    func clearChartHistory() { chartHistoryResetRevision += 1 }
    func startMetricsLoop() { IntelPowerMetricsService.shared.start(intervalMs: metricsIntervalMs) }
    private static let intervals = [250, 500, 1_000, 2_000, 5_000]
    func increaseMetricsInterval() {
        let next = Self.intervals.first { $0 > metricsIntervalMs } ?? Self.intervals.last!
        if next != metricsIntervalMs { metricsIntervalMs = next }
    }
    func decreaseMetricsInterval() {
        let next = Self.intervals.last { $0 < metricsIntervalMs } ?? Self.intervals.first!
        if next != metricsIntervalMs { metricsIntervalMs = next }
    }
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
    static let power = MetricsChartDefinition(
        title: "Power", unitLabel: "Watt",
        helpMarkdown: "Package power reported by powermetrics.",
        showsSampleTime: true,
        schemaBuilder: { metrics in AnyHashable(metrics?.power.package != nil) },
        seriesBuilder: { metrics in
            if metrics?.power.package != nil {
                return [MetricsSeriesDescriptor(
                    title: "PKG", color: MetricsChartPalette.package, kind: .line,
                    chartValue: { $0.power.package ?? 0 },
                    detailsFormatter: { String(format: "%.2f", locale: FormatLocale.posix, $0) }
                )]
            }
            return []
        }
    )
    static let frequency = MetricsChartDefinition(
        title: "Frequency, usage", unitLabel: "GHz, %",
        helpMarkdown: "Each CPU package has a frequency line and a shaded area for active core usage.",
        schemaBuilder: { metrics in AnyHashable(metrics?.cpu_usage.map(\.name) ?? []) },
        seriesBuilder: { metrics in
            if let metrics {
                return metrics.cpu_usage.enumerated().flatMap { index, cluster in
                    let color = MetricsChartPalette.cpuFrequencyPalette[index % MetricsChartPalette.cpuFrequencyPalette.count]
                    return [
                        MetricsSeriesDescriptor(
                            title: cluster.name, color: color, kind: .line,
                            chartValue: { Double($0.cpu_usage[index].frequencyMHz) / 1000 },
                            detailsFormatter: { String(format: "%.2f", locale: FormatLocale.posix, $0) },
                            detailsGroup: "cpu.\(index)"
                        ),
                        MetricsSeriesDescriptor(
                            title: cluster.name, color: color.withAlphaComponent(0.3), kind: .fill,
                            chartValue: { Double($0.cpu_usage[index].frequencyMHz) / 1000 * $0.cpu_usage[index].usage },
                            detailsValue: { $0.cpu_usage[index].usage },
                            detailsFormatter: { String(format: "%.1f%%", locale: FormatLocale.posix, $0 * 100) },
                            detailsGroup: "cpu.\(index)"
                        ),
                    ]
                }
            }
            return []
        }
    )
}

// MARK: - SwiftUI content for the popover/window
struct ContentView: View {
    @ObservedObject private var dependencies = AppDependencies.shared
    @ObservedObject private var batteryTrackerService = BatteryTrackerService.shared
    @ObservedObject private var intelPowerService = IntelPowerMetricsService.shared
    @ObservedObject var presentationState: MenuPresentationState
    @State private var highlightedChartSampleX: Double?
    @State private var isBatteryTrackerPopoverPresented = false
    @State private var permissionPromptShown = false
    @State private var lastPresentedFailure = 0
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
                            .frame(height: metrics.size.height * 0.4)
                            .background(backgroundColor)
                            .padding(chartSectionInsets)

                        MetricsChartSection(
                            definition: MetricsChartDefinitions.frequency,
                            metricsPublisher: dependencies.metricsPublisher,
                            capacity: AppPresentation.chartHistoryCapacity,
                            showUpdates: presentationState.isWindowVisible,
                            historyResetRevision: dependencies.chartHistoryResetRevision,
                            highlightedSampleX: $highlightedChartSampleX
                        )
                            .background(backgroundColor)
                            .padding(chartSectionInsets)

                    }
                }
            if let error = intelPowerService.errorMessage {
                HStack {
                    Text(error).font(AppFonts.systemMessage).textSelection(.enabled)
                    Spacer()
                    if intelPowerService.needsPermission {
                        Button("Set Up Permission") {
                            intelPowerService.requestPermissionAndRetry(intervalMs: dependencies.metricsIntervalMs)
                        }
                    } else {
                        Button("Retry") { dependencies.startMetricsLoop() }
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
        .onAppear {
            showPermissionIfNeeded()
            showFailureIfNeeded()
        }
        .onChange(of: intelPowerService.needsPermission) { _, _ in showPermissionIfNeeded() }
        .onChange(of: intelPowerService.failureRevision) { _, _ in showFailureIfNeeded() }
    }

    private func showPermissionIfNeeded() {
        if intelPowerService.needsPermission && !permissionPromptShown {
            permissionPromptShown = true
            NSApp.activate()
            intelPowerService.requestPermissionAndRetry(intervalMs: dependencies.metricsIntervalMs)
        }
    }

    private func showFailureIfNeeded() {
        if intelPowerService.failureRevision > lastPresentedFailure {
            lastPresentedFailure = intelPowerService.failureRevision
            NSApp.activate()
            intelPowerService.presentFailureAlert(intervalMs: dependencies.metricsIntervalMs)
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--helpers-uninstall") {
            Task {
                let services: [(String, SMAppService)] = [
                    ("Battery tracker", .agent(plistName: BatteryTrackerConstants.launchAgentPlistName)),
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


        let aboutItem = NSMenuItem(title: "About...", action: #selector(showAboutPanel), keyEquivalent: "")
        aboutItem.target = self
        statusItemMenu.addItem(aboutItem)


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

    @objc private func quitApplication() {
        IntelPowerMetricsService.shared.stop()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        IntelPowerMetricsService.shared.stop()
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
        let metricsCredit = "Metrics from Apple's powermetrics"

        let credits = NSMutableAttributedString(try! AttributedString(
            markdown: """
MIT licensed
[Source code](https://github.com/homm/StillCore)

\(metricsCredit)

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
                Button("About \(AppPresentation.floatingWindowTitle)") {
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
