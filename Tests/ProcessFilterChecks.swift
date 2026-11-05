import Foundation

@main
struct ProcessFilterChecks {
    static func check(_ condition: Bool, _ message: String) {
        if !condition {
            print("FAIL: \(message)")
            exit(1)
        }
    }

    static func main() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer {
            if child.isRunning {
                child.terminate()
                child.waitUntilExit()
            }
        }
        let childPID = child.processIdentifier
        let process = ProcessReading(
            id: .init(pid: childPID, start: 1),
            isBackground: false, cpu: nil, gpu: nil, memory: 0, power: nil
        )
        check(process.matches(name: "", pid: nil), "An empty filter must match every process")
        check(process.matches(name: "LEe", pid: nil), "Names must match substrings without case sensitivity")
        check(!process.matches(name: "Other", pid: nil), "Unrelated names must not match")
        check(process.matches(name: String(childPID), pid: childPID), "An exact PID must match")
        let partialPID = String(childPID).dropLast()
        check(!process.matches(name: String(partialPID), pid: pid_t(partialPID)), "Numbers must not match partial PIDs or names")
        let overflowingPID = "999999999999999999999999"
        check(!process.matches(name: overflowingPID, pid: pid_t(overflowingPID) ?? 0), "An overflowing PID must not match")
        check(process.matches(name: "sleep", pid: nil, processIDs: [childPID]), "Text and application filters must match together")
        check(!process.matches(name: "Other", pid: nil, processIDs: [childPID]), "Application membership must not bypass text filtering")
        check(!process.matches(name: "sleep", pid: nil, processIDs: [0]), "Text matches outside the application must be excluded")
        check(process.matches(name: String(childPID), pid: childPID, processIDs: [childPID]), "An exact PID inside the application must match")
        check(!process.matches(name: String(childPID), pid: childPID, processIDs: [0]), "An exact PID must not bypass the application filter")
        check(!process.matches(name: "", pid: nil, processIDs: []), "An empty application tree must match no processes")

        let parents: [pid_t: pid_t] = [
            500: 1, 400: 300, 300: 200, 200: 100, 100: 1,
            600: 1, 700: 600, 800: 700, 900: 1
        ]
        let parentPID: (pid_t) -> pid_t? = { parents[$0] }
        var snapshot = ProcessSnapshot()
        snapshot.readings = parents.keys.map {
            ProcessReading(id: .init(pid: $0, start: 1), isBackground: false,
                           cpu: nil, gpu: nil, memory: 0, power: nil)
        }
        let responsibilities: [pid_t: pid_t] = [500: 400, 400: 400, 300: 300, 200: 200, 100: 100,
                                               600: 100, 700: -1, 800: 0, 900: 900]
        let responsiblePID: (pid_t) -> pid_t = { responsibilities[$0] ?? -1 }
        check(snapshot.processIDs(root: 100, applicationPIDs: [100, 400], responsiblePID: responsiblePID, parentPID: parentPID) == [100, 200, 300, 600, 700, 800],
              "An application must include descendants and XPC services but exclude another application and its services")
        check(snapshot.processIDs(root: 400, applicationPIDs: [100, 400], responsiblePID: responsiblePID, parentPID: parentPID) == [400, 500],
              "Selecting a nested application must include its own services without ancestors")
        check(snapshot.processIDs(root: 100, applicationPIDs: [100], responsiblePID: responsiblePID, parentPID: parentPID) == [100, 200, 300, 400, 500, 600, 700, 800],
              "Changing the application list must update filtering using the same process snapshot")
        var intermediate = snapshot
        intermediate.readings.removeAll { $0.id.pid == 200 }
        check(intermediate.processIDs(root: 100, applicationPIDs: [100, 400], responsiblePID: responsiblePID, parentPID: parentPID) == [100, 300, 600, 700, 800],
              "An unsampled ancestor must still connect its sampled descendants to the application")
        check(snapshot.processIDs(root: 100, applicationPIDs: [100, 400], responsiblePID: responsiblePID,
                                  parentPID: { $0 == 200 ? 300 : parentPID($0) }) == [100, 600, 700, 800],
              "A parent cycle outside the selected application must terminate and exclude its processes")
        check(snapshot.processIDs(root: 100, applicationPIDs: [100, 400], responsiblePID: {
            $0 == 200 ? 300 : responsiblePID($0)
        }, parentPID: parentPID) == [100, 600, 700, 800], "A responsibility cycle must terminate and exclude its processes")
        check(snapshot.processIDs(root: 100, applicationPIDs: [100, 400], responsiblePID: responsiblePID,
                                  parentPID: { $0 == 200 ? nil : parentPID($0) }) == [100, 600, 700, 800],
              "An unavailable ancestor must not connect descendants to the application")
        snapshot.readings.append(process)
        let childResponsibility: (pid_t) -> pid_t = { $0 == childPID ? 100 : responsiblePID($0) }
        check(process.matches(name: "sleep", pid: nil, processIDs: snapshot.processIDs(root: 100, applicationPIDs: [100, 400], responsiblePID: childResponsibility, parentPID: parentPID)),
              "Text filtering must find a process attributed to the selected application through responsibility")
        check(!process.matches(name: "sleep", pid: nil, processIDs: snapshot.processIDs(root: 400, applicationPIDs: [100, 400], responsiblePID: childResponsibility, parentPID: parentPID)),
              "A matching process attributed to another application must be excluded")
        let sampler = ProcessSampler()
        let running = sampler.sample()
        check(running.readings.contains { $0.id.pid == childPID },
              "The snapshot must record a running child process")
        check(ProcessSampler.parentPID(childPID) == getpid(), "PPID lookup must return the live parent")
        check(running.processIDs(root: getpid(), applicationPIDs: [getpid()], responsiblePID: { _ in -1 }).contains(childPID),
              "Live PPID lookup must find a child when responsibility is unavailable")
        child.terminate()
        child.waitUntilExit()
        check(!process.matches(name: "sleep", pid: nil), "Name filtering must query the live process instead of retaining its old name")
        check(ProcessSampler.parentPID(childPID) == nil, "PPID lookup must fail for an exited child")
        check(!sampler.sample().readings.contains { $0.id.pid == childPID },
              "Refreshing the snapshot must remove exited children")

        let sample = ProcessSampler().sample()
        let current = sample.readings.first { $0.id.pid == getpid() }
        check(current?.name.isEmpty == false, "A sampled process must provide its system name on demand")
        print("PASS: process filters, parent and responsible links, application boundaries, XPC services and live snapshots")
    }
}
