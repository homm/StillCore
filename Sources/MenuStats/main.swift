import SwiftUI
import AppKit
import os

let log = Logger(subsystem: "com.user.MenuStats", category: "stream")

func sanitizeANSI(_ input: String) -> String {
    var s = input
    // Убираем возврат каретки + erase line (например "\r\u{1B}[2K")
    s = s.replacingOccurrences(of: "\r", with: "")
    s = s.replacingOccurrences(of: "\u{1B}[2K", with: "")    
    return s
}

func attributedFromANSI(_ input: String) -> NSAttributedString {
    let result = NSMutableAttributedString()
    var attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
        .foregroundColor: NSColor.labelColor
    ]

    let pattern = #"\u001B\[(\d+)(;\d+)*m"#
    let regex = try! NSRegularExpression(pattern: pattern)
    let s = sanitizeANSI(input)

    var pos = s.startIndex
    for match in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
        let r = Range(match.range, in: s)!
        let before = String(s[pos..<r.lowerBound])
        result.append(NSAttributedString(string: before, attributes: attributes))

        // разбор кодов
        let codes = s[r].dropFirst(2).dropLast().split(separator: ";").compactMap { Int($0) }
        for code in codes {
            switch code {
            case 0: // reset
                attributes[.foregroundColor] = NSColor.labelColor
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            case 1: // bold
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
            case 39: attributes[.foregroundColor] = NSColor.labelColor

            case 30: attributes[.foregroundColor] = NSColor.black
            case 31: attributes[.foregroundColor] = NSColor.systemRed
            case 32: attributes[.foregroundColor] = NSColor.systemGreen
            case 33: attributes[.foregroundColor] = NSColor.systemYellow
            case 34: attributes[.foregroundColor] = NSColor.systemBlue
            case 35: attributes[.foregroundColor] = NSColor.magenta
            case 36: attributes[.foregroundColor] = NSColor.systemCyan
            case 37: attributes[.foregroundColor] = NSColor.white

            default: break
            }
        }
        pos = r.upperBound
    }
    if pos < s.endIndex {
        result.append(NSAttributedString(string: String(s[pos...]), attributes: attributes))
    }
    return result
}


// MARK: - LogTextView: NSTextView в SwiftUI-обёртке, построчный API + capacity

struct LogTextView: NSViewRepresentable {
    /// Вернуть координатор наружу (чтобы писать в него и/или менять capacity)
    var onReady: (Coordinator) -> Void

    final class Coordinator {
        let textView: NSTextView
        private(set) var lineCount: Int = 0
        private var capacity: Int = 1000   // единственный источник правды

        init(textView: NSTextView) {
            self.textView = textView
        }

        // Меняем лимит строк; сразу подрезаем лишнее, если уже превышен
        func setCapacity(_ newValue: Int) {
            capacity = max(0, newValue)
            while lineCount > capacity { dropFirstLine() }
        }

        // Построчное добавление без пересборки всего текста
        func appendLine(_ line: String) {
            guard !line.isEmpty else { return }
            let shouldAutoscroll = isAtBottom(threshold: 4)

            let s = textView.string.isEmpty ? line : "\n" + line
            textView.textStorage?.append(attributedFromANSI(s))

            lineCount += 1
            while lineCount > capacity { dropFirstLine() }
            
            if shouldAutoscroll {
                scrollVerticallyToBottom()
            }
        }

        func clear() {
            textView.string = ""
            lineCount = 0
        }

        func scrollVerticallyToBottom() {
            guard let scrollView = textView.enclosingScrollView else { return }
            let clip = scrollView.contentView

            // Обновляем лейаут, чтобы знать реальную высоту контента
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)

            // Сохраняем текущий X, меняем только Y
            let currentX = textView.visibleRect.minX
            clip.setBoundsOrigin(NSPoint(x: currentX, y: textView.bounds.height))
            scrollView.reflectScrolledClipView(clip)
        }

        // MARK: - Внутренние утилиты

        private func isAtBottom(threshold: CGFloat = 0) -> Bool {
            return textView.visibleRect.maxY >= textView.bounds.height - threshold
        }

        private func dropFirstLine() {
            guard let storage = textView.textStorage, storage.length > 0 else { return }
            let s = storage.string as NSString
            let nl = s.range(of: "\n")
            let cutLen = (nl.location == NSNotFound) ? storage.length : nl.location + 1
            storage.deleteCharacters(in: NSRange(location: 0, length: cutLen))
            lineCount = max(0, lineCount - 1)
        }
    }

    // MARK: NSViewRepresentable

    func makeCoordinator() -> Coordinator {
        let tv = NSTextView()
        tv.isEditable = false
        tv.drawsBackground = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = true
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.lineFragmentPadding = 0

        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        let coord = Coordinator(textView: tv)
        onReady(coord)
        return coord
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = context.coordinator.textView
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
    }
}


// MARK: - Процесс со стримингом stdout/stderr, без оболочки

final class StreamedProcess: ObservableObject {
    private var task: Process?
    private var stdoutPipe: Pipe?
    @Published var isRunning = false

    func start(
        command: String,
        args: [String] = [],
        workingDir: URL? = nil,
        lineHandler: @escaping (String) -> Void
    ) {
        stop()

        let task = Process()
        task.launchPath = command
        task.arguments = args
        if let wd = workingDir { task.currentDirectoryURL = wd }

        let out = Pipe()
        task.standardOutput = out
        self.stdoutPipe = out

        out.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if !data.isEmpty, let s = String(data: data, encoding: .utf8) {
                s.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                    .forEach { line in 
                        lineHandler(String(line))
                    }
            }
        }

        do {
            try task.run()
            self.task = task
            self.isRunning = true
        } catch {
            lineHandler("[error] failed to start: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard let t = task else { return }
        t.terminate()
        t.waitUntilExit()
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        task = nil
        isRunning = false
    }
}

// MARK: - Helpers
enum RunOnce {
    static func run(_ cmd: String, _ args: [String]) -> String? {
        let p = Process()
        p.launchPath = cmd
        p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return "[error] \(error.localizedDescription)" }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}

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
    @ObservedObject var dependencies = AppDependencies.shared
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
                let status = RunOnce.run("~/.bin/battery_tracker", ["status"]) ?? "(no output)"
                DispatchQueue.main.async {
                    self.lastBatteryStatus = status.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
    }
}

// MARK: - App entry (MenuBarExtra ensures icon exists)
@main
struct MenuStatsApp: App {
    init() {
        AppDependencies.shared.restartStream(2000)
    }

    var body: some Scene {
        MenuBarExtra("MenuStats", systemImage: "chart.bar.xaxis") {
            ContentView()
                .frame(width: 420, height: 300)
        }
        .menuBarExtraStyle(.window)
    }
}
