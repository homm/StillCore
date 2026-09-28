import Foundation

final class PowerMetricsEngine: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "PowerMetricsHelper")
    private let listener: NSXPCListener
    private var clients: [UUID: NSXPCConnection] = [:]
    private var activeClients: Set<UUID> = []
    private var processID: pid_t?
    private var processExit: DispatchSourceProcess?
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
        connection.remoteObjectInterface = NSXPCInterface(with: PowerMetricsClientProtocol.self)
        connection.invalidationHandler = { [weak self] in
            guard let self else { return }
            queue.async {
                self.clients.removeValue(forKey: id)
                self.activeClients.remove(id)
                if self.clients.isEmpty {
                    self.shutdown()
                } else if self.activeClients.isEmpty {
                    self.stopProcess()
                }
            }
        }
        queue.sync { clients[id] = connection }
        connection.resume()
        return true
    }

    fileprivate func start(for id: UUID, reply: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in
            guard self.clients[id] != nil else { return }
            self.activeClients.insert(id)
            if self.processID != nil {
                reply(nil)
                return
            }

            do {
                let pid = try Self.spawnPowerMetrics()
                self.processID = pid
                let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: self.queue)
                source.setEventHandler { [weak self] in
                    guard let self, self.processID == pid else { return }
                    var status: Int32 = 0
                    while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
                    self.processID = nil
                    self.processExit?.cancel()
                    self.processExit = nil
                    let message = status & 0x7f == 0
                        ? "powermetrics stopped (exit status \(status >> 8))."
                        : "powermetrics stopped (signal \(status & 0x7f))."
                    for id in self.activeClients {
                        let client = self.clients[id]?.remoteObjectProxyWithErrorHandler { _ in }
                            as? PowerMetricsClientProtocol
                        client?.powerMetricsStopped(message)
                    }
                    self.activeClients.removeAll()
                }
                self.processExit = source
                source.resume()
                reply(nil)
            } catch {
                self.activeClients.remove(id)
                reply("Could not start powermetrics: \(error.localizedDescription)")
            }
        }
    }

    private func stopProcess() {
        guard let pid = processID else { return }
        processID = nil
        processExit?.cancel()
        processExit = nil
        kill(pid, SIGTERM)
        var status: Int32 = 0
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while true {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid || (result == -1 && errno != EINTR) { break }
            if result == -1 { continue }
            if clock.now >= deadline {
                kill(pid, SIGKILL)
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
                break
            }
            usleep(20_000)
        }
    }

    static func spawnPowerMetrics() throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        var signals = sigset_t()
        sigemptyset(&signals)
        sigaddset(&signals, SIGTERM)
        sigaddset(&signals, SIGINT)
        posix_spawnattr_setsigdefault(&attributes, &signals)
        sigemptyset(&signals)
        posix_spawnattr_setsigmask(&attributes, &signals)
        // Inherit the helper's process group so launchd also cleans up this child.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        let command: [String] = ["/usr/sbin/taskpolicy", "-c", "background", "/usr/bin/powermetrics", "--samplers", "gpu_power", "-i", "400"]
        var arguments = command.map { argument in argument.withCString { strdup($0) } } + [nil]
        defer { arguments.forEach { free($0) } }
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        var pid: pid_t = 0
        let status = arguments.withUnsafeMutableBufferPointer { argv in
            environment.withUnsafeMutableBufferPointer { env in
                posix_spawn(&pid, "/usr/sbin/taskpolicy", &actions, &attributes,
                            argv.baseAddress!, env.baseAddress!)
            }
        }
        guard status == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(status))
        }
        return pid
    }

    private func shutdown() {
        listener.invalidate()
        stopProcess()
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
