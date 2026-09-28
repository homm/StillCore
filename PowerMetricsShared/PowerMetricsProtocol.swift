import Foundation
import MachO
import Security

@objc(PowerMetricsHelperProtocol) protocol PowerMetricsHelperProtocol {
    func start(reply: @escaping @Sendable (String?) -> Void)
}

@objc(PowerMetricsClientProtocol) protocol PowerMetricsClientProtocol {
    func powerMetricsStopped(_ message: String)
}

enum PowerMetricsConstants {
    static let plistName = "com.github.homm.StillCore.PowerMetrics.plist"
    static let helperName = "PowerMetricsHelper"

    static func executableURL() -> URL {
        var length: UInt32 = 0
        _NSGetExecutablePath(nil, &length)
        var path = [CChar](repeating: 0, count: Int(length))
        _NSGetExecutablePath(&path, &length)
        return path.withUnsafeBufferPointer {
            URL(fileURLWithPath: String(cString: $0.baseAddress!)).resolvingSymlinksInPath()
        }
    }

    static let serviceName = "com.github.homm.StillCore.PowerMetrics"

    static func signingRequirement(for executable: URL) throws -> String {
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(executable as CFURL, [], &code)
        guard status == errSecSuccess, let code else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        var requirement: SecRequirement?
        status = SecCodeCopyDesignatedRequirement(code, [], &requirement)
        guard status == errSecSuccess, let requirement else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        var text: CFString?
        status = SecRequirementCopyString(requirement, [], &text)
        guard status == errSecSuccess, let text else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return text as String
    }
}
