import AppKit

final class StreamedProcess: ObservableObject {
    private var powermetrics: Process?
    private var pgauge: Process?
    private var midPipe: Pipe?
    private var outPipe: Pipe?
    private var errPipe: Pipe?

    func start(
        pGaugeCommand: String,
        powerMetricsArgs: [String] = [],
        lineHandler: @escaping @MainActor (String) -> Void
    ) {
        stop()

        let mid = Pipe()
        let out = Pipe()
        let err = Pipe()
        let powErr = Pipe()
        self.midPipe = mid
        self.outPipe = out
        self.errPipe = err

        let pow = Process()
        pow.launchPath = "/usr/bin/sudo"
        pow.arguments = ["-n", "/usr/bin/powermetrics"] + powerMetricsArgs
        pow.standardOutput = mid
        pow.standardError = powErr

        powErr.fileHandleForReading.readabilityHandler = { handler in
            let data = handler.availableData
            if data.isEmpty {
                handler.readabilityHandler = nil
            } else if let s = String(data: data, encoding: .utf8) {
                let msg = "[powermetrics] \(s.trimmingCharacters(in: .whitespacesAndNewlines))"
                Task { @MainActor in lineHandler(msg) }
            }
        }

        let gau = Process()
        gau.launchPath = pGaugeCommand
        gau.standardInput = mid
        gau.standardOutput = out
        gau.standardError = err

        out.fileHandleForReading.readabilityHandler = { handler in
            let data = handler.availableData
            if data.isEmpty {
                handler.readabilityHandler = nil
            } else if let s = String(data: data, encoding: .utf8) {
                s.split(whereSeparator: \.isNewline)
                    .forEach { line in
                        Task { @MainActor in lineHandler(String(line)) }
                    }
            }
        }
        
        do {
            try gau.run()
            self.pgauge = gau
            try pow.run()
            self.powermetrics = pow
        } catch {
            let msg = "[error] failed to start: \(error.localizedDescription)"
            Task { @MainActor in lineHandler(msg) }
            stop()
            return
        }
    }

    func stop() {
        outPipe?.fileHandleForReading.readabilityHandler = nil
        errPipe?.fileHandleForReading.readabilityHandler = nil
        midPipe = nil
        outPipe = nil
        errPipe = nil

        powermetrics?.terminate()
        pgauge?.terminate()
        powermetrics?.waitUntilExit()
        pgauge?.waitUntilExit()

        powermetrics = nil
        pgauge = nil
    }
}

func run_once(_ cmd: String, _ args: [String]) -> String? {
    let p = Process()
    p.launchPath = cmd
    p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return "[error] \(error.localizedDescription)" }
    p.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)
}
