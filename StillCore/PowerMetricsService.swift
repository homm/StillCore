import Foundation
import ServiceManagement

@MainActor
final class PowerMetricsService: HelperService {
    static let shared = PowerMetricsService()
    private var connection: NSXPCConnection?
    private var connectionID: UUID?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var startTimeout: Task<Void, Never>?

    private init() {
        super.init(service: .daemon(plistName: PowerMetricsConstants.plistName),
                   helperName: PowerMetricsConstants.helperName)
    }

    override func initialize() {
        if #unavailable(macOS 27.0) { return }
        super.initialize()
    }

    override func prepareForOperation() {
        disconnect()
    }

    override func ensureRunning() async throws {
        if #unavailable(macOS 27.0) { throw HelperFailure("CPU power updates require macOS 27.") }
        let requirement: String
        do {
            let executable = Bundle.main.bundleURL
                .appendingPathComponent("Contents/MacOS/\(PowerMetricsConstants.helperName)")
            requirement = try PowerMetricsConstants.signingRequirement(for: executable)
        } catch {
            throw HelperFailure("Could not verify the CPU power helper: \(error.localizedDescription)")
        }
        let connection = NSXPCConnection(machServiceName: PowerMetricsConstants.serviceName, options: .privileged)
        connection.setCodeSigningRequirement(requirement)
        try await connect(connection)
    }

    func connect(_ connection: NSXPCConnection) async throws {
        if self.connection != nil { return }
        let id = UUID()
        connection.remoteObjectInterface = NSXPCInterface(with: PowerMetricsHelperProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: PowerMetricsClientProtocol.self)
        connection.exportedObject = PowerMetricsClient { [weak self] message in
            Task { @MainActor in self?.failed(message, connectionID: id) }
        }
        connection.invalidationHandler = { @Sendable [weak self] in
            Task { @MainActor in
                self?.failed("The CPU power helper disconnected. Try starting it again.", connectionID: id)
            }
        }
        connection.interruptionHandler = { @Sendable [weak self] in
            Task { @MainActor in
                self?.failed("The CPU power helper stopped. Try starting it again.", connectionID: id)
            }
        }
        self.connection = connection
        connectionID = id
        do {
            try await withCheckedThrowingContinuation { continuation in
                startContinuation = continuation
                startTimeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) }
                    catch { return }
                    if let self, self.connectionID == id {
                        self.completeStart(.failure(HelperFailure("The CPU power helper did not respond. Try starting it again.")))
                    }
                }
                connection.resume()
                let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable [weak self] error in
                    let message = error.localizedDescription
                    Task { @MainActor in self?.failed(message, connectionID: id) }
                }
                if let helper = proxy as? PowerMetricsHelperProtocol {
                    helper.start { [weak self] error in
                        Task { @MainActor in
                            if let self, self.connectionID == id {
                                if let error { self.completeStart(.failure(HelperFailure(error))) }
                                else { self.completeStart(.success(())) }
                            }
                        }
                    }
                } else {
                    completeStart(.failure(HelperFailure("Could not create the CPU power helper XPC proxy.")))
                }
            }
        } catch {
            disconnect()
            throw error
        }
    }

    private func failed(_ message: String, connectionID: UUID) {
        if self.connectionID != connectionID { return }
        if startContinuation != nil {
            completeStart(.failure(HelperFailure(message)))
        } else {
            disconnect()
            reportFailure(message)
        }
    }

    private func completeStart(_ result: Result<Void, Error>) {
        startTimeout?.cancel()
        startTimeout = nil
        let continuation = startContinuation
        startContinuation = nil
        continuation?.resume(with: result)
    }

    private func disconnect() {
        if startContinuation != nil { completeStart(.failure(CancellationError())) }
        connectionID = nil
        connection?.invalidate()
        connection = nil
    }
}

private final class PowerMetricsClient: NSObject, PowerMetricsClientProtocol, Sendable {
    private let onStop: @Sendable (String) -> Void

    init(onStop: @escaping @Sendable (String) -> Void) {
        self.onStop = onStop
    }

    func powerMetricsStopped(_ message: String) {
        onStop(message)
    }
}
