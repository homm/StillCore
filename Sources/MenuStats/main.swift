import os
import SwiftUI

let log = Logger(subsystem: "com.user.MenuStats", category: "stream")


// MARK: - DI: точка доступа к лог-тексту и процессу

final class AppDependencies: ObservableObject {
    static let shared = AppDependencies()

    @Published var logHeader: AttributedString = ""
    weak var log: LogTextView.Coordinator?
    private var pendingLines: [String] = []
    let streamer = StreamedProcess()

    // Подставь свою команду/аргументы
    var streamCommand: String = "/Users/master/Code/_env/env_py39/bin/pgauge"
    var streamArgs: [String] = "-s 0 -p -i".components(separatedBy: " ")

    func restartStream(_ interval: Int) {
        streamer.stop()

        let args = streamArgs + [String(interval)]
        var headerSet = false
        streamer.start(command: streamCommand, args: args) { [weak self] line in
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

            if !dependencies.logHeader.characters.isEmpty {
                Text(dependencies.logHeader)
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
                .frame(minWidth: 420, minHeight: 300)
                .background(WindowConfigurator())
        }
        .menuBarExtraStyle(.window)
    }
}
