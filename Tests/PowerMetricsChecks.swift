import Combine
import Foundation
import Security
import ServiceManagement

@main
struct PowerMetricsChecks {
    @MainActor
    static func main() async throws {
        precondition(geteuid() != 0, "Run these checks without root privileges.")
        let bundle = Bundle(path: CommandLine.arguments[1])!
        let app = bundle.executableURL!
        let helper = bundle.bundleURL.appendingPathComponent("Contents/MacOS/PowerMetricsHelper")
        let plistURL = bundle.bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/\(PowerMetricsConstants.plistName)")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as! [String: Any]
        let label = PowerMetricsConstants.serviceName
        precondition(plist["Label"] as? String == label)
        precondition(plist["MachServices"] as? [String: Bool] == [label: true])
        precondition(plist["RunAtLoad"] == nil && plist["KeepAlive"] == nil)
        precondition(plist["AbandonProcessGroup"] as? Bool != true)
        precondition(plist["UserName"] == nil)
        precondition(plist["BundleProgram"] as? String == "Contents/MacOS/PowerMetricsHelper")
        print("PASS: bundled daemon is root, on demand, and uses the shared service name")
        try checkRegistrationFingerprint()
        try await checkRefreshLifecycle()
        try await checkRuntimeLifecycle()
        checkBatteryHeartbeat()
        let agentURL = bundle.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/com.github.homm.StillCore.BatteryTracker.plist")
        let agent = try PropertyListSerialization.propertyList(from: Data(contentsOf: agentURL), format: nil) as! [String: Any]
        precondition(agent["Label"] as? String == "com.github.homm.StillCore.BatteryTracker")
        print("PASS: both helpers use shared service labels")

        for (expected, rejected) in [(app, helper), (helper, app)] {
            let text = try PowerMetricsConstants.signingRequirement(for: expected)
            var requirement: SecRequirement?
            precondition(SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess)
            for (executable, shouldMatch) in [(expected, true), (rejected, false), (URL(fileURLWithPath: "/bin/sleep"), false)] {
                var code: SecStaticCode?
                precondition(SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess)
                let matches = SecStaticCodeCheckValidity(code!, [], requirement) == errSecSuccess
                precondition(matches == shouldMatch, "Unexpected signing match: \(executable.path)")
            }
        }
        print("PASS: app and helper requirements accept their executable and reject unrelated executables")

        let checkExecutable = PowerMetricsConstants.executableURL()
        precondition(FileManager.default.isExecutableFile(atPath: checkExecutable.path))
        try checkConnection(requirement: PowerMetricsConstants.signingRequirement(for: checkExecutable), accepts: true)
        try checkConnection(requirement: PowerMetricsConstants.signingRequirement(for: helper), accepts: false)
        print("PASS: XPC accepts a matching signature and rejects an unrelated client")

        let absentRegistration = CheckManualService(
            service: .agent(plistName: "Missing-\(UUID()).plist"), helperName: "MissingHelper"
        )
        absentRegistration.refresh()
        await absentRegistration.start()
        precondition(absentRegistration.status == .stopped
                     && absentRegistration.errorMessage?.hasPrefix("Install failed:") == true,
                     "A missing helper must leave Start available and explain the installation failure")
        await absentRegistration.start()
        precondition(absentRegistration.status == .stopped
                     && absentRegistration.errorMessage?.hasPrefix("Install failed:") == true,
                     "A failed installation must remain retryable")
        print("PASS: failed installation leaves Start available for another attempt")

        let absentService = PowerMetricsService.shared
        absentService.initialize()
        precondition(absentService.status == .stopped && absentService.errorMessage == nil, "An unregistered service must offer Start, not an error")
        print("PASS: an absent service offers installation")

        let service = PowerMetricsService.shared
        do {
            try await service.connect(NSXPCConnection(machServiceName: "com.github.homm.StillCore.Tests.Missing.\(UUID())", options: .privileged))
            preconditionFailure("An unavailable helper must fail startup")
        } catch {
            precondition(!error.localizedDescription.isEmpty)
        }
        print("PASS: an XPC connection error reaches MainActor without an isolation trap")

        let silentListener = NSXPCListener.anonymous()
        let silentDelegate = CheckListener(defersReply: true)
        silentListener.delegate = silentDelegate
        silentListener.resume()
        do {
            try await service.connect(NSXPCConnection(listenerEndpoint: silentListener.endpoint))
            preconditionFailure("A helper that never replies must time out")
        } catch {
            precondition(error.localizedDescription.contains("did not respond"))
        }
        silentDelegate.replyToStart()
        try await Task.sleep(for: .milliseconds(50))

        let listener = NSXPCListener.anonymous()
        let delegate = CheckListener()
        listener.delegate = delegate
        listener.resume()
        let connectedService = PowerMetricsService.shared
        try await connectedService.connect(NSXPCConnection(listenerEndpoint: listener.endpoint))
        precondition(delegate.startCount == 1, "A start reply must confirm the helper accepted the request")
        silentDelegate.replyToStart()
        try await Task.sleep(for: .milliseconds(50))
        silentListener.invalidate()
        try await connectedService.connect(NSXPCConnection(listenerEndpoint: listener.endpoint))
        precondition(delegate.startCount == 1, "A duplicate connection must not send another start request")
        delegate.notifyStop("Sampling stopped unexpectedly")
        let failureDeadline = ContinuousClock.now + .seconds(2)
        while connectedService.errorMessage == nil && ContinuousClock.now < failureDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(connectedService.status == .stopped && connectedService.errorMessage == "Sampling stopped unexpectedly",
                     "An unexpected process exit must stop the service and expose separate error details")
        connectedService.refresh()
        precondition(connectedService.status == .stopped && delegate.startCount == 1,
                     "Polling after a process error must not restart sampling")
        try await connectedService.connect(NSXPCConnection(listenerEndpoint: listener.endpoint))
        precondition(delegate.startCount == 2, "An explicit reconnect must confirm a fresh start")
        listener.invalidate()
        print("PASS: start confirmation and duplicate connections preserve the connection lifecycle")

        let process = Process()
        process.executableURL = helper
        try process.run()
        process.waitUntilExit()
        precondition(process.terminationStatus == EXIT_FAILURE)
        print("PASS: the helper refuses to run without root")

        let pid = try PowerMetricsEngine.spawnPowerMetrics()
        precondition(getpgid(pid) == getpgrp(), "powermetrics must stay in the helper's process group")
        var status: Int32 = 0
        precondition(waitpid(pid, &status, 0) == pid)
        precondition(status != 0, "powermetrics must refuse sampling without root")
        precondition(waitpid(pid, &status, WNOHANG) == -1 && errno == ECHILD)
        print("PASS: the child inherits the helper's group and is reaped after exit")
    }

    @MainActor
    private static func checkRuntimeLifecycle() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults(suiteName: "com.github.homm.StillCore.HelperRegistrations")?.removeObject(forKey: "Helper")
        }
        let executableDirectory = directory.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
        for name in ["Helper", "StillCore"] {
            try Data(name.utf8).write(to: executableDirectory.appendingPathComponent(name))
        }

        let appService = CheckAppService()
        appService.reportedStatus = .notRegistered
        let service = CheckRuntimeService(service: appService, helperName: "Helper", bundleURL: directory)
        precondition(service.status == .running && appService.statusReadCount == 0,
                     "Construction must request no user action and must not inspect system status")
        service.refresh()
        var statuses: [HelperService.Status] = []
        let subscription = service.$status.sink { statuses.append($0) }
        service.timeout = 0.2
        let start = Task { await service.start() }
        let deadline = ContinuousClock.now + .seconds(1)
        while service.starts == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        precondition(service.starts == 1 && service.status == .starting)
        precondition(appService.registerCount == 1 && appService.unregisterCount == 0,
                     "Start must install an absent helper")
        await service.start()
        precondition(service.starts == 1 && appService.registerCount == 1,
                     "Repeated Start during startup must not register or start twice")
        service.confirm()
        await start.value
        precondition(statuses == [.stopped, .starting, .running],
                     "Registration must proceed directly from starting to confirmed running")
        await service.start()
        precondition(service.starts == 1, "Start while running must do nothing")
        try await Task.sleep(for: .milliseconds(250))
        precondition(service.status == .running && service.errorMessage == nil,
                     "Confirmation must cancel the old timeout")

        service.reportFailure("Process exited")
        let startsAfterExit = service.starts
        service.refresh()
        precondition(service.status == .stopped && service.errorMessage == "Process exited" && service.starts == startsAfterExit,
                     "Polling must preserve failure details without starting again")
        service.timeout = 0.05
        await service.start()
        precondition(appService.unregisterCount == 0 && appService.registerCount == 1,
                     "A manual Start must reconnect an unchanged helper without re-registering it")
        precondition(service.status == .stopped && service.errorMessage == "No runtime confirmation",
                     "A missing confirmation must leave starting after the runtime timeout")
        service.refresh()
        precondition(service.starts == startsAfterExit + 1, "A timeout must not produce an automatic retry")

        service.timeout = 1
        appService.reportedStatus = .requiresApproval
        service.refresh()
        precondition(service.status == .requiresApproval)
        let registrationsBeforeApproval = appService.registerCount
        await service.start()
        precondition(appService.registerCount == registrationsBeforeApproval,
                     "Start must not re-register a helper waiting for approval")
        let startsBeforeApproval = service.starts
        appService.reportedStatus = .enabled
        service.refresh()
        precondition(service.status == .starting && service.errorMessage == nil,
                     "Approval must automatically begin runtime confirmation")
        let approvalDeadline = ContinuousClock.now + .seconds(1)
        while service.starts == startsBeforeApproval && ContinuousClock.now < approvalDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        precondition(service.starts == startsBeforeApproval + 1)
        appService.reportedStatus = .requiresApproval
        service.confirm()
        while service.status == .starting && ContinuousClock.now < approvalDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        precondition(service.status == .requiresApproval,
                     "A confirmation after revocation must not mark the service running before the next poll")
        service.refresh()
        precondition(service.status == .requiresApproval, "Revocation during startup must end waiting")
        try await Task.sleep(for: .milliseconds(1100))
        precondition(service.status == .requiresApproval && service.errorMessage == nil,
                     "A revoked attempt's timeout must not overwrite approval status")

        let pendingAppService = CheckAppService()
        pendingAppService.reportedStatus = .notRegistered
        pendingAppService.requiresApproval = true
        let pendingService = CheckRuntimeService(service: pendingAppService, helperName: "Helper", bundleURL: directory)
        pendingService.refresh()
        await pendingService.start()
        precondition(pendingService.status == .requiresApproval && pendingService.starts == 0,
                     "Installation requiring approval must never pretend to start the runtime")

        try Data("Updated helper".utf8).write(to: executableDirectory.appendingPathComponent("Helper"))
        let deferredService = CheckRuntimeService(service: pendingAppService, helperName: "Helper", bundleURL: directory)
        deferredService.refresh()
        let registrationsBeforeUpdate = pendingAppService.registerCount
        let removalsBeforeUpdate = pendingAppService.unregisterCount
        precondition(deferredService.status == .requiresApproval && deferredService.errorMessage == nil,
                     "A changed build awaiting approval must not produce an update error")
        precondition(pendingAppService.registerCount == registrationsBeforeUpdate && pendingAppService.unregisterCount == removalsBeforeUpdate,
                     "An unapproved service must not be registered or unregistered automatically")
        pendingAppService.requiresApproval = false
        pendingAppService.reportedStatus = .enabled
        deferredService.refresh()
        precondition(deferredService.status == .starting && deferredService.starts == 0,
                     "Approval must check the deferred registration before starting the helper")
        let updateDeadline = ContinuousClock.now + .seconds(1)
        while deferredService.starts == 0 && deferredService.errorMessage == nil && ContinuousClock.now < updateDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        precondition(deferredService.starts == 1 && pendingAppService.registerCount == registrationsBeforeUpdate + 1
                     && pendingAppService.unregisterCount == removalsBeforeUpdate + 1,
                     "Approval must register the changed build before runtime confirmation")
        deferredService.confirm()

        let failedUpdateAppService = CheckAppService()
        failedUpdateAppService.reportedStatus = .requiresApproval
        let failedUpdateService = CheckRuntimeService(service: failedUpdateAppService, helperName: "MissingHelper", bundleURL: directory)
        failedUpdateService.refresh()
        precondition(failedUpdateService.status == .requiresApproval && failedUpdateService.errorMessage == nil,
                     "Waiting for approval must not even fingerprint a missing executable")
        failedUpdateAppService.reportedStatus = .enabled
        failedUpdateService.refresh()
        let failureDeadline = ContinuousClock.now + .seconds(1)
        while failedUpdateService.status == .starting && ContinuousClock.now < failureDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let updateError = failedUpdateService.errorMessage
        precondition(failedUpdateService.status == .stopped && updateError?.hasPrefix("Update failed:") == true,
                     "A failed deferred update must end startup and expose its own error")
        failedUpdateService.refresh()
        precondition(failedUpdateService.status == .stopped && failedUpdateService.errorMessage == updateError && failedUpdateService.starts == 0,
                     "Polling must not hide or retry a failed deferred update")
        withExtendedLifetime(subscription) {}
        print("PASS: Start installs or reconnects, confirmation and timeout end waiting, approval changes cancel old attempts")
    }

    private static func checkBatteryHeartbeat() {
        var state = BatteryTrackerState(heartbeatAt: Date())
        let previousHeartbeat = state.heartbeatAt
        precondition(state.isRunning(), "A healthy fresh heartbeat confirms an existing tracker")
        precondition(!state.isRunning(after: previousHeartbeat), "An old record must not confirm a restarted tracker")
        state.heartbeatAt = previousHeartbeat.addingTimeInterval(1)
        precondition(state.isRunning(after: previousHeartbeat), "A new healthy heartbeat must confirm the restarted tracker")
        state.heartbeatAt = Date().addingTimeInterval(-BatteryTrackerConstants.heartbeatTimeout - 1)
        precondition(!state.isRunning(), "An expired heartbeat must not report running")
        state.heartbeatAt = Date()
        state.lastError = "Tracking failed"
        precondition(!state.isRunning(), "A fresh heartbeat with a helper error must not report running")
        state.lastError = nil
        precondition(state.isRunning(), "A recovered heartbeat must confirm tracking again")
        print("PASS: battery confirmation rejects old, stale and erroneous heartbeats and accepts recovery")
    }

    @MainActor
    private static func checkRefreshLifecycle() async throws {
        let appService = CheckAppService()
        let service = CheckRefreshingService(service: appService, helperName: "MissingHelper")
        precondition(service.status == .running && appService.statusReadCount == 0,
                     "The initial status must require no action until refresh discovers otherwise")
        precondition(service.refreshCount == 0, "Base initialization must not call the subclass refresh")
        var publishedStatuses: [HelperService.Status] = []
        var objectChanges = 0
        let statusSubscription = service.$status.sink { publishedStatuses.append($0) }
        let objectSubscription = service.objectWillChange.sink { objectChanges += 1 }
        appService.reportedStatus = .requiresApproval
        service.refresh()
        precondition(service.status == .requiresApproval)
        precondition(publishedStatuses == [.running, .requiresApproval])
        precondition(objectChanges == 2, "Both inherited status and subclass runtime updates must notify observers")
        service.refresh()
        precondition(publishedStatuses.count == 2, "An unchanged status must not be published again")
        precondition(objectChanges == 3, "Subclass runtime updates must still publish when status is unchanged")

        appService.reportedStatus = .enabled
        service.refresh()
        precondition(service.status == .starting, "Approval must begin checking the registered helper")
        let updateDeadline = ContinuousClock.now + .seconds(1)
        while service.status == .starting && ContinuousClock.now < updateDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        precondition(service.status == .stopped && service.errorMessage?.hasPrefix("Update failed:") == true,
                     "An approved helper with a missing executable must stop and explain the update failure")
        service.refresh()
        precondition(service.status == .stopped && service.errorMessage != nil,
                     "Polling must preserve registration errors without another attempt")
        appService.reportedStatus = .requiresApproval
        service.refresh()
        precondition(service.status == .requiresApproval && service.errorMessage == nil,
                     "A changed system status must clear the error so approval can resume the service")

        let absentAppService = CheckAppService()
        absentAppService.reportedStatus = .notRegistered
        let startingService = CheckInitializingService(service: absentAppService, helperName: "MissingHelper")
        precondition(startingService.initializeCount == 0 && startingService.refreshCount == 0,
                     "Base construction must defer overridden initialization until the subclass is ready")
        let initializationDeadline = ContinuousClock.now + .seconds(1)
        while !startingService.initialized && ContinuousClock.now < initializationDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        precondition(startingService.initialized && startingService.initializeCount == 1,
                     "The base constructor must automatically initialize the subclass exactly once")
        precondition(startingService.status == .stopped, "Common startup must not install without consent")
        precondition(startingService.errorMessage == nil)
        let refreshesAfterStartup = startingService.refreshCount
        startingService.initialize()
        precondition(startingService.refreshCount == refreshesAfterStartup, "Repeated startup must not check or start polling twice")

        let deadline = ContinuousClock.now + .seconds(4)
        while startingService.refreshCount == refreshesAfterStartup && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(startingService.refreshCount == refreshesAfterStartup + 1,
                     "Initialization must schedule one periodic refresh")
        withExtendedLifetime((statusSubscription, objectSubscription)) {}
        print("PASS: inherited status and runtime publish, polling uses one timer")
    }

    @MainActor
    private static func checkRegistrationFingerprint() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundle = directory.appendingPathComponent("StillCore.app")
        let plistPath = "Contents/Library/LaunchDaemons/helper.plist"
        let helperPath = "Contents/MacOS/Helper"
        let appPath = "Contents/MacOS/StillCore"
        defer { try? FileManager.default.removeItem(at: directory) }
        for path in [plistPath, helperPath, appPath] {
            let url = bundle.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("original".utf8).write(to: url)
        }
        func registration(_ url: URL) -> CheckManualService {
            CheckManualService(service: .agent(plistName: "Fixture.plist"), helperName: "Helper", bundleURL: url)
        }
        func fingerprint(_ url: URL) throws -> String {
            try registration(url).fingerprint()
        }
        let cachedRegistration = registration(bundle)
        let original = try cachedRegistration.fingerprint()
        let unchanged = try fingerprint(bundle)
        precondition(unchanged == original, "An unchanged bundle must not restart helpers")
        let plistURL = bundle.appendingPathComponent(plistPath)
        try Data("modified".utf8).write(to: plistURL)
        let changedPlist = try fingerprint(bundle)
        precondition(changedPlist == original, "Plist contents must not affect the fingerprint")
        try FileManager.default.removeItem(at: plistURL)
        let missingPlist = try fingerprint(bundle)
        precondition(missingPlist == original, "Fingerprinting must not require a plist path")
        for path in [helperPath, appPath] {
            let url = bundle.appendingPathComponent(path)
            try Data("modified".utf8).write(to: url)
            let modified = try fingerprint(bundle)
            precondition(modified != original, "A new instance must detect binary changes without a version bump")
            let cached = try cachedRegistration.fingerprint()
            precondition(cached == original, "An existing instance must reuse its fingerprint")
            try Data("original".utf8).write(to: url)
        }
        let moved = directory.appendingPathComponent("Moved.app")
        try FileManager.default.moveItem(at: bundle, to: moved)
        let movedFingerprint = try fingerprint(moved)
        precondition(movedFingerprint == original, "Moving an unchanged app must not restart helpers")
        let alias = directory.appendingPathComponent("Alias.app")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: moved)
        let aliasFingerprint = try fingerprint(alias)
        precondition(aliasFingerprint == movedFingerprint, "Accessing the app through a symlink must not restart helpers")
        try FileManager.default.removeItem(at: moved.appendingPathComponent(helperPath))
        let cachedAfterMove = try cachedRegistration.fingerprint()
        precondition(cachedAfterMove == original, "A cached fingerprint must not read files again")
        let retryRegistration = registration(moved)
        do {
            _ = try retryRegistration.fingerprint()
            preconditionFailure("Missing helper must produce an error, never a successful fingerprint")
        } catch CocoaError.fileReadNoSuchFile {}
        try Data("original".utf8).write(to: moved.appendingPathComponent(helperPath))
        let retried = try retryRegistration.fingerprint()
        precondition(retried == original, "Fingerprint errors must allow a subsequent retry")
        print("PASS: fingerprints are cached per instance, detect new binaries on a new instance, and allow retry after errors")
    }

    private static func checkConnection(requirement: String, accepts: Bool) throws {
        let listener = NSXPCListener.anonymous()
        let delegate = CheckListener()
        listener.delegate = delegate
        listener.setConnectionCodeSigningRequirement(requirement)
        listener.resume()
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: PowerMetricsHelperProtocol.self)
        connection.resume()
        let done = DispatchSemaphore(value: 0)
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            precondition(!accepts, "A matching XPC client was rejected")
            done.signal()
        } as! PowerMetricsHelperProtocol
        proxy.start { _ in
            precondition(accepts, "An unrelated XPC client was accepted")
            done.signal()
        }
        precondition(done.wait(timeout: .now() + 5) == .success)
        connection.invalidate()
        listener.invalidate()
    }
}

private final class CheckListener: NSObject, NSXPCListenerDelegate, PowerMetricsHelperProtocol {
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var starts = 0
    private let defersReply: Bool
    private var pendingReply: (@Sendable (String?) -> Void)?
    var startCount: Int { lock.withLock { starts } }

    init(defersReply: Bool = false) { self.defersReply = defersReply }

    func replyToStart() {
        let reply = lock.withLock { pendingReply }
        reply?(nil)
    }

    func notifyStop(_ message: String) {
        let connection = lock.withLock { connection }
        let client = connection?.remoteObjectProxy as? PowerMetricsClientProtocol
        client?.powerMetricsStopped(message)
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: PowerMetricsHelperProtocol.self)
        connection.exportedObject = self
        connection.remoteObjectInterface = NSXPCInterface(with: PowerMetricsClientProtocol.self)
        lock.withLock { self.connection = connection }
        connection.resume()
        return true
    }

    func start(reply: @escaping @Sendable (String?) -> Void) {
        lock.withLock {
            starts += 1
            if defersReply { pendingReply = reply }
        }
        if !defersReply { reply(nil) }
    }
}

private final class CheckAppService: SMAppService {
    var reportedStatus: SMAppService.Status = .enabled
    var statusReadCount = 0
    override var status: SMAppService.Status {
        statusReadCount += 1
        return reportedStatus
    }
    var registerCount = 0
    var unregisterCount = 0
    var requiresApproval = false

    override func register() throws {
        registerCount += 1
        reportedStatus = requiresApproval ? .requiresApproval : .enabled
    }

    override func unregister() async throws {
        unregisterCount += 1
        if reportedStatus == .requiresApproval {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        }
        reportedStatus = .notRegistered
    }
}

@MainActor
private class CheckManualService: HelperService {
    // These checks drive operations explicitly without a concurrent automatic startup.
    override func initialize() {}
}

@MainActor
private final class CheckInitializingService: HelperService {
    var initializeCount = 0
    var refreshCount = 0
    var initialized = false

    override func initialize() {
        initializeCount += 1
        super.initialize()
        initialized = true
    }

    override func refresh() {
        super.refresh()
        refreshCount += 1
    }
}

@MainActor
private final class CheckRuntimeService: CheckManualService {
    var starts = 0
    var timeout: TimeInterval = 1
    private var confirmed = false

    func confirm() { confirmed = true }

    override func ensureRunning() async throws {
        starts += 1
        confirmed = false
        let deadline = ContinuousClock.now + .seconds(timeout)
        while status == .starting {
            if confirmed { return }
            if ContinuousClock.now >= deadline { throw HelperFailure("No runtime confirmation") }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CancellationError()
    }
}

@MainActor
private final class CheckRefreshingService: CheckManualService {
    @Published private(set) var refreshCount = 0

    override func refresh() {
        super.refresh()
        refreshCount += 1
    }
}
