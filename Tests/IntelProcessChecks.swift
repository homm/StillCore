import Combine
import Foundation

@main
struct IntelProcessChecks {
    @MainActor
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stillcore-intel-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("sampler")
        let sampleURL = directory.appendingPathComponent("sample.plist")
        let service = IntelPowerMetricsService(executableURL: executable, arguments: { _ in [] })

        try writeScript("#!/bin/sh\nprintf 'sudo: a password is required\\n' >&2\nexit 1\n", to: executable)
        service.start(intervalMs: 250)
        try await waitUntil { service.needsPermission }
        precondition(service.failureRevision == 0)

        try writeScript("#!/bin/sh\nprintf 'hardware unavailable\\n' >&2\nexit 2\n", to: executable)
        service.start(intervalMs: 250)
        try await waitUntil { service.failureRevision == 1 }
        precondition(service.errorMessage?.contains("hardware unavailable") == true)

        let sample = try PropertyListSerialization.data(fromPropertyList: [
            "processor": [
                "package_watts": 7.0,
                "packages": [["average_num_cores": 1.0, "cores": [["cpus": [["freq_hz": 2_000_000_000.0]]]]]],
            ],
        ], format: .xml, options: 0)
        try sample.write(to: sampleURL)
        try writeScript("#!/bin/sh\n/bin/cat '\(sampleURL.path)'\nexec /bin/sleep 30\n", to: executable)
        var received: Metrics?
        let subscription = service.publisher.sink { received = $0 }
        service.start(intervalMs: 250)
        try await waitUntil { received != nil }
        precondition(received?.power.package == 7.0)
        service.stop()
        try await Task.sleep(for: .milliseconds(200))
        precondition(service.errorMessage == nil)
        subscription.cancel()
        print("PASS: sudo refusal, process failure, sample delivery, retry and clean stop")
    }

    private static func writeScript(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url, options: .atomic)
        if chmod(url.path, 0o700) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    @MainActor
    private static func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(predicate(), "Timed out waiting for the expected process state")
    }
}
