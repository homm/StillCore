import Foundation

guard #available(macOS 27.0, *), geteuid() == 0 else {
    exit(EXIT_FAILURE)
}

do {
    let executableDirectory = PowerMetricsConstants.executableURL().deletingLastPathComponent()
    let engine = try PowerMetricsEngine(appExecutable: executableDirectory.appendingPathComponent("StillCore"))
    engine.run()
} catch {
    fputs("PowerMetricsHelper: \(error.localizedDescription)\n", stderr)
    NSLog("PowerMetricsHelper: %@", error.localizedDescription)
    exit(EXIT_FAILURE)
}
