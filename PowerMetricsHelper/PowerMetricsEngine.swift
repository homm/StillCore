import Foundation

final class PowerMetricsEngine: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "PowerMetricsHelper")
    private let listener: NSXPCListener
    private var clients: [UUID: NSXPCConnection] = [:]
    private var terminationSignal: DispatchSourceSignal?

    init(appExecutable: URL) throws {
        listener = NSXPCListener(machServiceName: PowerMetricsConstants.serviceName)
        super.init()
        listener.setConnectionCodeSigningRequirement(
            try PowerMetricsConstants.signingRequirement(for: appExecutable)
        )
        listener.delegate = self
    }

    func run() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        source.setEventHandler { [weak self] in self?.shutdown() }
        source.resume()
        terminationSignal = source
        listener.resume()
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.clients.isEmpty else { return }
            self.shutdown()
        }
        dispatchMain()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let id = UUID()
        connection.exportedInterface = NSXPCInterface(with: PowerMetricsHelperProtocol.self)
        connection.exportedObject = PowerMetricsSession(engine: self, id: id)
        connection.invalidationHandler = { [weak self] in
            guard let self else { return }
            queue.async {
                self.clients.removeValue(forKey: id)
                if self.clients.isEmpty {
                    self.shutdown()
                }
            }
        }
        queue.sync { clients[id] = connection }
        connection.resume()
        return true
    }

    fileprivate func start(for id: UUID, reply: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in
            if self.clients[id] != nil {
                reply(nil)
            }
        }
    }

    private func shutdown() {
        listener.invalidate()
        exit(EXIT_SUCCESS)
    }
}

private final class PowerMetricsSession: NSObject, PowerMetricsHelperProtocol, @unchecked Sendable {
    private let engine: PowerMetricsEngine
    private let id: UUID

    init(engine: PowerMetricsEngine, id: UUID) {
        self.engine = engine
        self.id = id
    }

    func start(reply: @escaping @Sendable (String?) -> Void) {
        engine.start(for: id, reply: reply)
    }

}
