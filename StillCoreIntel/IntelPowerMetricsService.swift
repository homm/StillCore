import AppKit
import Combine
import Foundation

@MainActor
final class IntelPowerMetricsService: ObservableObject {
    static let shared = IntelPowerMetricsService()

    @Published private(set) var errorMessage: String?
    @Published private(set) var needsPermission = false
    @Published private(set) var failureRevision = 0
    private let samples = PassthroughSubject<Metrics, Never>()
    private var process: Process?
    private var stdout: Pipe?
    private var stderr: Pipe?
    private var parser = IntelMetricsParser()
    private var errorOutput = ""
    private var generation = 0
    private var receivedSample = false
    private let executableURL: URL
    private let arguments: (Int) -> [String]

    var publisher: AnyPublisher<Metrics, Never> { samples.eraseToAnyPublisher() }

    init(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/sudo"),
        arguments: @escaping (Int) -> [String] = { intervalMs in
            ["-n", "/usr/bin/powermetrics", "--samplers", "cpu_power", "--format", "plist", "-i", String(intervalMs)]
        }
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
    }

    func start(intervalMs: Int) {
        stop()
        errorMessage = nil
        needsPermission = false
        parser = IntelMetricsParser()
        errorOutput = ""
        receivedSample = false
        let id = generation
        let output = Pipe()
        let errors = Pipe()
        let task = Process()
        task.executableURL = executableURL
        task.arguments = arguments(intervalMs)
        task.standardOutput = output
        task.standardError = errors
        stdout = output
        stderr = errors
        process = task

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                Task { @MainActor [weak self] in
                    if let self, self.generation == id {
                        for metrics in self.parser.append(data) {
                            self.receivedSample = true
                            self.samples.send(metrics)
                        }
                    }
                }
            }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                Task { @MainActor [weak self] in
                    if let self, self.generation == id {
                        self.errorOutput += String(decoding: data, as: UTF8.self)
                    }
                }
            }
        }
        task.terminationHandler = { [weak self] ended in
            let code = ended.terminationStatus
            Task { @MainActor [weak self] in
                // Let the stderr readability callback deliver the final chunk.
                try? await Task.sleep(for: .milliseconds(50))
                if let self, self.generation == id {
                    let output = self.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.process = nil
                    self.closePipes()
                    if output.contains("sudo:") || output.contains("password is required") {
                        self.needsPermission = true
                        self.errorMessage = "Administrator permission is needed to start powermetrics."
                    } else {
                        self.reportFailure(output.isEmpty
                            ? "powermetrics stopped (exit status \(code))."
                            : "powermetrics stopped: \(output)")
                    }
                }
            }
        }
        do {
            try task.run()
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(max(5_000, intervalMs * 3)))
                if let self, self.generation == id, self.process != nil, !self.receivedSample {
                    self.stop()
                    self.reportFailure("powermetrics started but did not produce a readable sample.")
                }
            }
        } catch {
            closePipes()
            process = nil
            reportFailure("Could not start powermetrics: \(error.localizedDescription)")
        }
    }

    private func reportFailure(_ message: String) {
        errorMessage = message
        failureRevision += 1
    }

    func presentFailureAlert(intervalMs: Int) {
        if let errorMessage {
            let alert = NSAlert()
            alert.messageText = "Could not read CPU metrics"
            alert.informativeText = "Command:\n/usr/bin/sudo -n /usr/bin/powermetrics --samplers cpu_power --format plist -i \(intervalMs)\n\nOutput:\n\(errorMessage)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Retry")
            alert.addButton(withTitle: "Close")
            if alert.runModal() == .alertFirstButtonReturn {
                start(intervalMs: intervalMs)
            }
        }
    }

    func stop() {
        generation += 1
        let oldProcess = process
        process = nil
        closePipes()
        if let oldProcess, oldProcess.isRunning {
            oldProcess.terminate()
        }
    }

    private func closePipes() {
        stdout?.fileHandleForReading.readabilityHandler = nil
        stderr?.fileHandleForReading.readabilityHandler = nil
        stdout = nil
        stderr = nil
    }

    func requestPermissionAndRetry(intervalMs: Int) {
        let rule = Self.sudoersRule(user: NSUserName())
        if !SudoersPermissionAlert.confirm(
            title: "Need permission to read CPU metrics",
            rule: rule
        ) {
            start(intervalMs: intervalMs)
            return
        }

        Task {
            let result = await SudoersPermissionAlert.install(rule: rule)
            let service = IntelPowerMetricsService.shared
            switch result {
            case .success:
                service.start(intervalMs: intervalMs)
            case .cancelled:
                service.start(intervalMs: intervalMs)
            case .failure(let output):
                service.errorMessage = "Permission setup failed: \(output)"
            }
        }
    }

    nonisolated static func sudoersRule(user: String) -> String {
        "\(user) ALL=(root) NOPASSWD: /usr/bin/powermetrics ^--samplers cpu_power --format plist -i [1-9][0-9]*$"
    }
}
