import Foundation

@main
struct ProcessFilterChecks {
    static func check(_ condition: Bool, _ message: String) {
        if !condition {
            print("FAIL: \(message)")
            exit(1)
        }
    }

    @MainActor
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
        var usage = rusage_info_v6()
        check(ProcessSampler.readUsage(childPID, into: &usage), "The child process must provide its identity")
        let process = ProcessReading(
            id: .init(pid: childPID, start: usage.ri_proc_start_abstime),
            isBackground: false, cpu: nil, gpu: nil, memory: 0, power: nil
        )
        var snapshot = ProcessSnapshot()
        snapshot.readings = [process]
        check(snapshot.match(name: "", pid: nil).contains { $0.id == process.id }, "An empty filter must match every process")
        check(snapshot.match(name: "LEe", pid: nil).contains { $0.id == process.id }, "Names must match substrings without case sensitivity")
        check(!snapshot.match(name: "Other", pid: nil).contains { $0.id == process.id }, "Unrelated names must not match")
        check(snapshot.match(name: String(childPID), pid: childPID).contains { $0.id == process.id }, "An exact PID must match")
        let partialPID = String(childPID).dropLast()
        check(!snapshot.match(name: String(partialPID), pid: pid_t(partialPID)).contains { $0.id == process.id }, "Numbers must not match partial PIDs or names")
        let overflowingPID = "999999999999999999999999"
        check(!snapshot.match(name: overflowingPID, pid: pid_t(overflowingPID) ?? 0).contains { $0.id == process.id }, "An overflowing PID must not match")
        check(snapshot.match(name: "sleep", pid: nil, processIDs: [childPID]).contains { $0.id == process.id }, "Text and application filters must match together")
        check(!snapshot.match(name: "Other", pid: nil, processIDs: [childPID]).contains { $0.id == process.id }, "Application membership must not bypass text filtering")
        check(!snapshot.match(name: "sleep", pid: nil, processIDs: [0]).contains { $0.id == process.id }, "Text matches outside the application must be excluded")
        check(snapshot.match(name: String(childPID), pid: childPID, processIDs: [childPID]).contains { $0.id == process.id }, "An exact PID inside the application must match")
        check(!snapshot.match(name: String(childPID), pid: childPID, processIDs: [0]).contains { $0.id == process.id }, "An exact PID must not bypass the application filter")
        check(!snapshot.match(name: "", pid: nil, processIDs: []).contains { $0.id == process.id }, "An empty application tree must match no processes")

        let parents: [pid_t: pid_t] = [
            500: 1, 400: 300, 300: 200, 200: 100, 100: 1,
            600: 1, 700: 600, 800: 700, 900: 1
        ]
        let parentPID: (pid_t) -> pid_t? = { parents[$0] }
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
        check(snapshot.match(name: "sleep", pid: nil, processIDs: snapshot.processIDs(root: 100, applicationPIDs: [100, 400], responsiblePID: childResponsibility, parentPID: parentPID)).contains { $0.id == process.id },
              "Text filtering must find a process attributed to the selected application through responsibility")
        check(!snapshot.match(name: "sleep", pid: nil, processIDs: snapshot.processIDs(root: 400, applicationPIDs: [100, 400], responsiblePID: childResponsibility, parentPID: parentPID)).contains { $0.id == process.id },
              "A matching process attributed to another application must be excluded")
        let sampler = ProcessSampler()
        let running = sampler.sample()
        check(running.readings.contains { $0.id.pid == childPID },
              "The snapshot must record a running child process")
        check(ProcessSampler.parentPID(childPID) == getpid(), "PPID lookup must return the live parent")
        check(running.processIDs(root: getpid(), applicationPIDs: [getpid()], responsiblePID: { _ in -1 }).contains(childPID),
              "Live PPID lookup must find a child when responsibility is unavailable")
        check(running.name(for: process) == "sleep",
              "Display names must fall back to the executable name for command-line processes")
        child.terminate()
        child.waitUntilExit()
        check(running.name(for: process) == "sleep",
              "A snapshot must retain a resolved display name after the process exits")
        check(ProcessSnapshot().name(for: process) == String(childPID),
              "A new snapshot must resolve names again and fall back to PID for an exited process")
        let reusedPID = ProcessReading(id: .init(pid: childPID, start: 2),
                                       isBackground: false, cpu: nil, gpu: nil, memory: 0, power: nil)
        check(running.name(for: reusedPID) == String(childPID),
              "The display name cache must distinguish process identities with the same PID")
        check(running.match(name: "sleep", pid: nil).contains { $0.id == process.id }, "Filtering must use the same cached name as display within a snapshot")
        var refreshed = ProcessSnapshot()
        refreshed.readings = [process]
        check(!refreshed.match(name: "sleep", pid: nil).contains { $0.id == process.id }, "A new snapshot must refresh the name used for filtering")
        check(ProcessSampler.parentPID(childPID) == nil, "PPID lookup must fail for an exited child")
        check(!sampler.sample().readings.contains { $0.id.pid == childPID },
              "Refreshing the snapshot must remove exited children")

        let sample = ProcessSampler().sample()
        let current = sample.readings.first { $0.id.pid == getpid() }
        check(current.map { !sample.name(for: $0).isEmpty } == true, "A sampled process must provide its name on demand")
        print("PASS: process filters, parent and responsible links, application boundaries, XPC services and live snapshots")
    }
}
