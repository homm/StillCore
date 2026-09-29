import Combine
import CryptoKit
import Foundation
import ServiceManagement

/// Owns registration and the user-facing result of starting a helper.
/// Subclasses establish and monitor the helper's actual work.
@MainActor
class HelperService: ObservableObject {
    enum Status: Equatable {
        case stopped
        case requiresApproval
        case starting
        case running
    }

    private let service: SMAppService
    // Distinguishes a new approval from a failure under an unchanged registration.
    private var lastServiceStatus: SMAppService.Status?
    // Until the first check, there is no action to request from the user.
    @Published var status: Status = .running
    @Published var errorMessage: String?
    private var refreshTimer: Timer?
    private let helperName: String
    private let bundleURL: URL
    private var cachedFingerprint: String?
    private let defaults = UserDefaults(suiteName: "com.github.homm.StillCore.HelperRegistrations")!
    // Keeps registration changes exclusive across suspension points on MainActor.
    private var isRegistering = false
    private var attemptID = UUID()

    /// Constructs the controller independently of whether this helper is available on this Mac.
    init(service: SMAppService, helperName: String, bundleURL: URL = Bundle.main.bundleURL) {
        self.helperName = helperName
        self.bundleURL = bundleURL
        self.service = service
        // The MainActor task runs after the entire subclass has finished initializing.
        Task { [weak self] in self?.initialize() }
    }

    /// Lets the fully constructed subclass decide whether to participate in automatic
    /// monitoring on this Mac. Kept out of init so that decision can use subclass state.
    func initialize() {
        if refreshTimer != nil { return }
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// User-authorized installation or retry after failure, available only when stopped.
    /// Unlike automatic activation, may install a missing helper. Completion is not
    /// proof of success; status and errorMessage are the outcome presented to the user.
    func start() async {
        if status != .stopped { return }
        status = .starting
        await activate(installMissing: true)
    }

    var isRegistered: Bool {
        !isRegistering && service.status == .enabled
    }

    /// Reacts to external registration changes; subclasses extend this with runtime health.
    /// Adopts an enabled helper on app launch or approval, but a runtime failure alone
    /// does not trigger another activation. May manage the service as well as observe it.
    func refresh() {
        if isRegistering { return }
        let serviceStatus = service.status
        if lastServiceStatus != serviceStatus {
            if lastServiceStatus != nil {
                attemptID = UUID()
                if errorMessage != nil { errorMessage = nil }
            }
            lastServiceStatus = serviceStatus
            if serviceStatus == .enabled {
                if status != .starting { status = .starting }
                Task { [weak self] in
                    if let self, self.lastServiceStatus == .enabled, self.status == .starting {
                        await self.activate(installMissing: false)
                    }
                }
            } else {
                let status: Status = serviceStatus == .requiresApproval ? .requiresApproval : .stopped
                if self.status != status { self.status = status }
            }
        }
    }

    /// Gives the subclass a chance to discard an attempt invalidated by registration changes.
    func prepareForOperation() {}

    /// Return only when this helper has confirmed that its work started.
    /// Each subclass owns its command, confirmation, and startup timeout.
    func ensureRunning() async throws {
        preconditionFailure("Subclasses must confirm that their helper is running")
    }

    /// Lets a subclass report a failure discovered after startup.
    func reportFailure(_ message: String) {
        attemptID = UUID()
        lastServiceStatus = service.status
        errorMessage = message
        let status: Status = lastServiceStatus == .requiresApproval ? .requiresApproval : .stopped
        if self.status != status { self.status = status }
    }

    isolated deinit {
        refreshTimer?.invalidate()
    }

    /// Makes the current app build the registered helper installation.
    /// Only activation policy should request this; replacement is not transactional.
    private func registerCurrentBuild() async throws {
        let fingerprint = try fingerprint()
        if service.status == .enabled {
            try await service.unregister()
        }
        if service.status != .requiresApproval {
            try service.register()
            defaults.set(fingerprint, forKey: helperName)
        }
    }

    /// Common activation policy for user Start and automatic adoption of an enabled helper.
    /// Separate from start because automatic activation must not install missing helpers.
    /// Owns registration readiness; delegates proof of working service to the subclass.
    private func activate(installMissing: Bool) async {
        if isRegistering { return }
        if service.status == .requiresApproval {
            lastServiceStatus = .requiresApproval
            status = .requiresApproval
            return
        }
        isRegistering = true
        let id = UUID()
        attemptID = id
        errorMessage = nil
        prepareForOperation()

        let wasRegistered = service.status == .enabled
        do {
            if wasRegistered {
                if defaults.string(forKey: helperName) != (try fingerprint()) {
                    try await registerCurrentBuild()
                }
            } else if installMissing {
                try await registerCurrentBuild()
            }
        } catch {
            errorMessage = "\(wasRegistered ? "Update" : "Install") failed: \(error.localizedDescription)"
        }

        isRegistering = false
        lastServiceStatus = service.status
        if attemptID != id { return }
        if lastServiceStatus == .enabled && errorMessage == nil {
            do {
                try await ensureRunning()
                if attemptID == id {
                    if service.status == .enabled { status = .running }
                    else { refresh() }
                }
            } catch {
                if attemptID == id {
                    if service.status == .enabled { reportFailure(error.localizedDescription) }
                    else { refresh() }
                }
            }
        } else {
            status = lastServiceStatus == .requiresApproval ? .requiresApproval : .stopped
        }
    }

    /// Decides whether an existing installation belongs to this app/helper build.
    /// Assumes executables remain unchanged during this controller's lifetime.
    func fingerprint() throws -> String {
        if cachedFingerprint == nil {
            var hash = SHA256()
            let appName = Bundle(url: bundleURL)?.executableURL?.lastPathComponent ?? "StillCore"
            for path in ["Contents/MacOS/\(helperName)", "Contents/MacOS/\(appName)"] {
                hash.update(data: Data(SHA256.hash(data: try Data(contentsOf: bundleURL.appendingPathComponent(path)))))
            }
            cachedFingerprint = hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return cachedFingerprint!
    }
}

struct HelperFailure: LocalizedError {
    let errorDescription: String?

    init(_ message: String) { errorDescription = message }
}
