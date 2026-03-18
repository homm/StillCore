import Foundation

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
